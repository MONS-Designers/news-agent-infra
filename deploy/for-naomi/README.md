# Handoff: automatic stage/prod deploy trigger for news-agent

These files aren't applied anywhere yet — they're for Moshe to copy into `news-agent` by hand
(or open as a PR there) once the Terraform in `news-agent-infra` has been applied. Nothing in
`news-agent-infra`'s automation touches `news-agent`'s repo directly.

This handoff replaces the manual/placeholder deploy flow from the previous handoff
(`spec-stage-deploy-baseline.md`) with the automatic one from `spec-gitops-deploy-trigger`: a
push to `dev` now reaches the live stage site, and a push to `main` now reaches the live prod
site, with no manual `az` command in between.

## Where each file goes, inside `news-agent`

| This file | Goes to | Notes |
|---|---|---|
| `Dockerfile.backend` | repo root, replacing the existing one | adds a `GIT_SHA` build-arg baked in as `ENV GIT_SHA` |
| `Dockerfile.frontend` | repo root, replacing the existing one | adds a `GIT_SHA` build-arg, writes a static `version.json` into the image |
| `trigger-deploy.yml` | `.github/workflows/trigger-deploy.yml` (new file) | **replaces** `docker-build-push.yml` — see Deletions below |
| `health-endpoint-diff.md` | not copied — it's instructions | small diff for `src/newsagent/api/main.py`, apply by hand |

`nginx.frontend.conf.template` is unchanged — no update needed. `version.json` is a static file
written into the image at `/usr/share/nginx/html/version.json`; nginx's existing `location /`
block (`try_files $uri $uri/ /index.html`) serves it directly like any other static asset,
because the file now genuinely exists — it never falls through to the SPA fallback.

## Deletions (do these in the same PR as adding the files above)

The old build/push pipeline is now fully replaced, not left dormant alongside the new one:

1. Delete `.github/workflows/docker-build-push.yml`.
2. In `news-agent`'s GitHub repo settings → Secrets and variables → Actions, delete the 3
   repository secrets it used: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
   The Azure login step that consumed them doesn't exist anywhere in `news-agent` any more — the
   whole build/push/deploy pipeline (including that login) now lives in `news-agent-infra`'s
   `deploy.yml` and `rollback.yml`, authenticating via its **own** re-pointed OIDC identity, not
   this repo's secrets.

## One-time setup before the new flow can run

Order matters — `deploy.yml`/`rollback.yml` authenticate via OIDC, which only works once the
federated identity is re-pointed at `news-agent-infra`'s own `main` branch, which only happens
once these workflow files are merged there and `terraform apply` has run. That's why the
bootstrap build (step 5) comes after `terraform apply` (step 4), not before — an earlier draft
of this README had that backwards and would have failed at the Azure login step with
`AADSTS700213`.

1. Merge this PR (`deploy.yml`, `rollback.yml`, `deploy/verify-commit.sh`,
   `deploy/resolve-rollback-sha.sh`, the `terraform/` changes) into `news-agent-infra`'s `main`.
   `repository_dispatch` only fires workflows that exist on the default branch, and
   `workflow_dispatch` only appears in the Actions UI for workflow files already on it — nothing
   below works until this lands.

2. Add 3 repository secrets to **`news-agent-infra`**'s GitHub settings (Settings → Secrets and
   variables → Actions), using `terraform -chdir=terraform output` values from the *existing*
   identity (these values don't change — only the federated identity's trusted subject does):
   - `AZURE_CLIENT_ID` ← `ci_identity_client_id`
   - `AZURE_TENANT_ID` ← `tenant_id`
   - `AZURE_SUBSCRIPTION_ID` ← `subscription_id`

   `deploy.yml` and `rollback.yml` both need these — they don't exist in this repo yet (they
   used to live only in `news-agent`, being deleted from there per the Deletions section above).

3. Add `news-agent`'s three files above (Dockerfiles + `trigger-deploy.yml`), apply the
   `/health` diff, and do the two deletions — **on both `dev` and `main`**. `trigger-deploy.yml`
   only fires on a push to a branch it already exists on, and the old `docker-build-push.yml`
   needs deleting from both, not just `dev`. `dev` is currently ahead of `main`, so the natural
   route is: land everything on `dev` first, then merge `dev` → `main` in `news-agent` (that
   merge itself will be prod's first real trigger, once `trigger-deploy.yml` exists on `main`).

4. Run `terraform -chdir=../../terraform apply` (after reviewing the plan) in `news-agent-infra`.
   This re-points the OIDC federated identity at `news-agent-infra`'s own `main` (step 1 above),
   adds `DOCKER_ENABLE_CI` to all 4 App Services, and switches them off the placeholder image
   onto the real ACR moving-tag image (`newsagent-api:stage-latest`, etc.) — which don't exist
   in ACR yet at this point, so stage briefly can't pull anything until step 5. Prod is
   unaffected either way — it's never had a real deploy. A full `apply` and living with the
   short stage gap is the simpler default; `terraform apply -target=...` is a targeted apply
   (Terraform's own docs discourage it for routine use — it can leave the plan/state out of sync
   with reality if used repeatedly) and should only be reached for if that gap genuinely can't be
   tolerated even once, applying just
   `-target=azurerm_federated_identity_credential.ci_acr_push_github` first, then the rest after
   step 5.

5. Trigger the first real build: in `news-agent-infra`, run the `deploy` workflow via
   `workflow_dispatch` (Actions tab → deploy → Run workflow) with `environment=stage` and
   `sha=<dev HEAD SHA after step 3>`. This should now pass its own verification end-to-end —
   step 3 already landed the `/health`/`version.json` changes, and step 4 already pointed the
   App Services at ACR. Repeat with `environment=prod` once `main` has the same changes (step 3).

6. Create the `news-agent` GitHub secret `INFRA_DISPATCH_TOKEN` (Settings → Secrets and
   variables → Actions → New repository secret): a **fine-grained PAT scoped only to
   `news-agent-infra`, `Contents: write`**, created by Moshe in GitHub's UI — this can't be
   automated or created by an agent. Without it, `trigger-deploy.yml` runs but its dispatch call
   fails with 401. This PAT is the one credential in this whole design that isn't OIDC-federated,
   so it expires (fine-grained PATs max out at 1 year) and needs manual rotation — **a 401 here
   later on is most likely just this PAT's TTL expiring, not a config/permissions bug.**

After that, every future push to `dev` or `main` deploys automatically — no more manual
`workflow_dispatch` runs needed for the steady-state flow.

## Resolved: `rollback.yml`'s `az acr import` needed a role beyond Credential A's `AcrPush`

Confirmed, not just suspected: `az role definition list -n AcrPush` shows its actions are only
`registries/pull/read` and `registries/push/write` — no import action. Microsoft's own docs for
same-registry import (`az acr import`) require the built-in role **`Container Registry Data
Importer and Data Reader`** on the target registry. Fixed in `terraform/main.tf` —
`ci_acr_import`, a second `azurerm_role_assignment` on the same `ci_acr_push` identity, scoped to
the shared ACR, granting that exact role. Applies (and needs verifying live) the next time
`terraform apply` runs.

## Resolved: fully automatic deploys vs. this repo's own `CLAUDE.md` deploy-verification rule

`news-agent-infra/CLAUDE.md`'s old "Deploy verification (definition of done)" section mandated
`deploy/smoke_test.py` plus a manual OAuth click after every deploy — written for a world where
deploys were rare, manual events. Under `deploy.yml`, a deploy happens on every push, with CAP-5
(`deploy/verify-commit.sh`) doing the automated commit-match verification instead. Moshe removed
that section from `CLAUDE.md` rather than trying to wire `smoke_test.py`/a real OAuth click into
every automatic push — `deploy/smoke_test.py` itself still exists and still runs on its own
schedule (`.github/workflows/smoke-test.yml`) as a standing regression check.

## Setting real Key Vault secret values

Unchanged from the previous handoff — `newsagent-api-stage`/`newsagent-api-prod` each read 4
secrets from the shared Key Vault (`newsagent-kv`, in `newsagent-shared-rg`) via Key Vault
references, resolved automatically at runtime — no code changes needed in `news-agent`. They
default to empty strings until set for real, either way works:

```bash
# Post-apply, via the CLI (fastest, no state file changes)
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-database-url --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-smtp-password --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-google-client-secret --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-session-secret --value "<real value>"
```

Same commands work for prod — swap `stage` for `prod` in every secret name. Or equivalently, put
the same values in a gitignored `terraform.tfvars` in `news-agent-infra/terraform/` and re-run
`terraform apply` — both paths land in the same secret.

## Rolling back

A separate `workflow_dispatch` workflow, `rollback.yml`, lives in `news-agent-infra` (not
handed over here — it never touches `news-agent`). Run it from the Actions tab with `service`
(`api` / `frontend` / `both`), `environment` (`stage` / `prod`), and an optional `sha`. With a
`sha`, it retags that exact already-built image as the environment's moving tag (no rebuild).
Without one, it rolls back exactly one step — to the build immediately before whichever one is
currently live. Either way it re-verifies against `/health`/`version.json` the same way a normal
deploy does.

Two caveats, documented in the workflow/script comments too:
- `service=both` runs the two chains sequentially; if the `api` chain fails, the `frontend`
  chain is skipped (visible in the run summary, not silent) rather than attempted independently
  — re-run with a single `service` to retry just the one that didn't happen.
- The no-`sha` "one step back" resolution assumes ACR's manifest ordering reflects creation time,
  not last-retag time (unverified against live behavior) — safe for a single hop, but for
  anything beyond one consecutive no-`sha` rollback, pass an explicit `sha` instead.

## Not included here (still deferred, see `deferred-work.md`)

- Per-environment Key Vault access isolation — each app's identity still has vault-level `Key
  Vault Secrets User` (both stage and prod share one vault).
- An approval/review gate before a deploy applies — both environments deploy fully automatically
  on push, by design (see `SPEC.md`'s Non-goals).
- Automatic rollback triggered by a failed health check — rollback stays a deliberate,
  manually-triggered action.
