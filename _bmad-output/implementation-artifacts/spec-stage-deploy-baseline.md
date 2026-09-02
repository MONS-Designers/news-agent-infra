---
title: 'Stage environment Terraform baseline + containerized backend/frontend for Azure App Service'
type: 'chore'
created: '2026-08-21'
status: 'in-progress'
review_loop_iteration: 0
context: []
baseline_commit: '042ce23f321a1e0c46aa81e86e6a7858e812568b'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** NewsAgent's only live environment is a single hand-provisioned VM (`az` CLI, no IaC) running the app directly via systemd — there is no environment to test infra or app changes before they hit production, and no containerized deploy path exists yet (`deploy/Dockerfile` builds a backend image, but nothing in Azure ever runs it).

**Approach:** Stand up a Terraform-managed stage environment (Azure App Service for Containers, Linux, `israelcentral`), and produce two lean Dockerfiles plus a GitHub Actions build workflow for Naomi's `news-agent` repo — handed over as files, not committed here — that build both frontend and backend and push to a shared Azure Container Registry. A shared Key Vault holds real secrets (renegotiated 2026-08-21, see Spec Change Log), consumed via App Service Key Vault references so `news-agent` needs zero code changes. Scope ends at "the real app runs in Azure, verified once by hand." The automatic deploy trigger (Azure Function polling a tag file) is deferred, out of scope here.

## Boundaries & Constraints

**Always:**
- Terraform state stays local (user's explicit choice) — no backend block, plain `terraform.tfstate`; add it and `.terraform/` to `.gitignore`, but commit `.terraform.lock.hcl`.
- New dedicated resource group `newsagent-shared-rg` in `israelcentral` holds resources reused across environments: the ACR (renamed `newsagentacr`, no `-stage` suffix — verified name-available) and the Key Vault. `newsagent-stage-rg` holds only the stage App Service Plan + the 2 stage web apps. Neither touches the existing `newsagent-rg` (the live VM); nothing gets imported.
- ACR: Basic SKU, admin user disabled. Push access is a user-assigned managed identity + GitHub OIDC federated credential (no stored Azure secret), role-assigned `AcrPush` only on this registry — "Credential A" from the earlier design discussion.
- One shared Linux App Service Plan (B1) hosts both `newsagent-api-stage` and `newsagent-frontend-stage`.
- **Key Vault (renegotiated 2026-08-21 — was deferred, now in scope):** RBAC authorization model (not legacy access policies), `purge_protection_enabled = false` / `soft_delete_retention_days = 7` (this is still a tear-down-able smoke-test slice, not prod — revisit purge protection when prod lands). Holds 4 secrets, named `newsagent-api-stage-{database-url,smtp-password,google-client-secret,session-secret}` (env-prefixed now so prod can add its own `-prod-` secrets in the same shared vault later without collision) — values come from new `sensitive = true` Terraform variables, default empty, real values supplied only via a gitignored `.tfvars`/`TF_VAR_*`, never hardcoded. Only `newsagent-api-stage`'s system-assigned identity gets `Key Vault Secrets User`, vault-scoped (not per-secret — Terraform can't validate a per-secret RBAC scope string at `plan` time, and there's nothing to over-isolate from yet since no prod secrets exist in the vault today; tightening this is deferred, logged in `deferred-work.md`). `newsagent-frontend-stage` gets no identity and no vault access — static SPA, nothing to fetch.
- Secrets reach the container via App Service Key Vault references (`@Microsoft.KeyVault(SecretUri=...)`) in `newsagent-api-stage`'s `app_settings` — Azure resolves these at runtime using the site's managed identity; the container sees a plain env var, so **no `news-agent` code changes**. The non-secret settings the API needs to actually run (`NEWSAGENT_FRONTEND_URL`/`BACKEND_BASE_URL` from the two web apps' own `default_hostname`, `NEWSAGENT_GOOGLE_CLIENT_ID`, SMTP host/port/username/from-address) go in as plain `app_settings` alongside them — every one of `news-agent`'s config fields has a Python-level default (verified against `origin/dev`'s `config.py`), so the container boots either way, but a meaningful smoke test needs these wired, not left on their placeholder defaults. `NEWSAGENT_EMAIL_SENDER` defaults to `console` (not `smtp`) so stage can't accidentally send real email before real SMTP creds are ever set.
- With local state (already-decided), secret values also land in `terraform.tfstate` in plaintext on disk — a known consequence of that earlier choice, not a new decision being relitigated here.
- Backend Dockerfile: adapt `deploy/Dockerfile`'s multi-stage / non-root / `python:3.12-slim` design, but drop its git-clone stage — it lives inside `news-agent`'s own repo, building from local context.
- Frontend Dockerfile: multi-stage (`node:20` build → minimal static server), SPA fallback matching `deploy/nginx.conf`'s `try_files ... /index.html`, non-root where the base image allows it.
- CI workflow builds both images tagged with the git SHA and pushes to ACR only — no tag file yet; nothing reads it until the (deferred) Azure Function exists.
- Never run `terraform apply` without first showing the `plan` diff and getting explicit go-ahead — every time.

**Ask First:**
- Any change touching the existing `newsagent-rg` or the live VM.
- Anything that would commit or push directly into the `news-agent` repo — this spec only produces files for the user to hand over himself.

**Never:**
- Provisioning the Azure Function or tag files — still deferred, logged in `deferred-work.md`. (Key Vault is no longer on this list — see above.)
- Editing anything inside the `news-agent` working tree directly.
- Enabling ACR's admin user or any other shared/static Azure credential.
- Per-secret Key Vault RBAC scoping in this slice — vault-level only (see above); do not hand-roll an unverified per-secret `scope` string.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Happy path | `terraform apply` succeeds, CI later pushes real images | Both stage App Services reachable, serving the real app after a manual image swap | N/A |
| App Service created before any image exists | No image pushed to ACR yet | Falls back to a placeholder container image, not a crash loop | Documented as expected, not a bug |
| `VITE_API_BASE` missing at frontend build time | CI builds the frontend image without the required build arg | Build fails loudly | Mirrors the existing `deploy/Dockerfile` pattern |
| Key Vault reference resolves before role assignment propagates | API app restarts right after `apply`, RBAC not yet propagated | App Service retries reference resolution automatically | Self-healing — not a bug; confirm by checking again after a short wait |
| Key Vault secret still has its empty default value | Real secret value never supplied via `.tfvars` | App boots (every config field has a Python-level default) but isn't meaningfully functional (e.g. DB calls fail) | Expected until real values are supplied — not this slice's job to supply them |

</frozen-after-approval>

## Code Map

- `deploy/Dockerfile` -- existing backend image design to adapt (multi-stage, non-root, `python:3.12-slim`); read-only reference
- `deploy/nginx.conf` -- existing SPA fallback config to mirror in the new frontend image; read-only reference
- `deploy/.env.example` -- names of the `NEWSAGENT_`-prefixed settings the backend App Service needs as app settings
- `_bmad-output/implementation-artifacts/mvp-launch-deploy-plan.md` -- region/naming conventions (`israelcentral`, `newsagent-` prefix); read-only reference
- `_bmad-output/implementation-artifacts/deferred-work.md` -- Key Vault entry now marked superseded/partially actioned here; per-environment secret isolation logged as a new deferred item — do not re-defer Key Vault itself
- `../news-agent/src/newsagent/config.py` (sibling repo, read-only) -- every `NEWSAGENT_*` setting and its default, verified against `origin/dev` 2026-08-21; drives which app_settings this spec wires

## Tasks & Acceptance

**Execution:**
- [x] `terraform/main.tf`, `terraform/variables.tf` -- resource group, ACR, user-assigned identity + federated credential + role assignment, App Service Plan, 2 Linux Web Apps for Containers -- the stage infra
- [x] `terraform/.gitignore` -- exclude state and provider cache, keep the lock file
- [x] `deploy/for-naomi/Dockerfile.backend` -- adapted from `deploy/Dockerfile`, no clone stage
- [x] `deploy/for-naomi/Dockerfile.frontend` -- new multi-stage build + static serve, SPA fallback (also added `deploy/for-naomi/nginx.frontend.conf`, `COPY`'d in by the Dockerfile — not a separate spec task, just required plumbing for the SPA fallback config)
- [x] `deploy/for-naomi/docker-build-push.yml` -- builds both images on push to `dev`, OIDC login, pushes to ACR with SHA tags
- [x] `deploy/for-naomi/README.md` -- where each file goes inside `news-agent`, and the one-time `az webapp config container set` commands to point stage at the first real image
- [x] `terraform/main.tf` -- add `newsagent-shared-rg`, move ACR into it renamed `newsagentacr`, add Key Vault (RBAC, purge protection off) + 4 secrets + vault-level `Key Vault Secrets User` role assignment scoped to the API app's identity, system-assigned identity on `newsagent-api-stage`, Key Vault reference + non-secret `app_settings` on the API app
- [x] `terraform/variables.tf` -- 4 `sensitive = true` secret-value variables (default empty) + non-secret stage config variables
- [x] `deploy/for-naomi/README.md` -- update ACR name references (`newsagentacr`, not `newsagentacrstage`) and add the Key Vault real-value setup step (`az keyvault secret set` or `.tfvars`)
- [x] `deploy/for-naomi/docker-build-push.yml` -- update `ACR_LOGIN_SERVER` to `newsagentacr.azurecr.io` (also caught a second stale reference in the `az acr login --name` step, same file)

**Acceptance Criteria:**
- ✅ Given `terraform plan` was reviewed and approved, when `terraform apply` runs, then the resource group, ACR, Key Vault, and both stage App Services exist in `israelcentral`. — met 2026-08-21.
- ✅ Given the handed-over CI workflow runs inside `news-agent` after Naomi merges it, when it completes, then both images exist in the shared ACR tagged with the triggering commit SHA. — met 2026-08-23: `newsagentacr` has `newsagent-api:bf204f0c8b0a7be4142d23bfb53adf190d307dc8` and `newsagent-frontend:` the same tag, from workflow run `32657806182` (confirmed via `az acr repository show-tags`, not just the CI green check).
- ✅ Given a real image tag from ACR, when it is manually set on a stage App Service, then hitting the app's default hostname returns the real app, not the placeholder. — met 2026-08-23: `newsagent-frontend-stage.azurewebsites.net/` → 200 (real nginx SPA), `newsagent-api-stage.azurewebsites.net/health` → 200, `.../api/health` (proxied through nginx) → 200.
- ⚠️ Given a real value is set for the `database-url` Key Vault secret, when `newsagent-api-stage` restarts, then its resolved app setting is the real value, not an unresolved Key Vault reference string. — **not independently confirmed.** Real values were set via `terraform.tfvars` + `apply`, and the container isn't crash-looping, but this criterion's own documented verification command (see Verification below) turns out not to prove it — it only echoes the raw `@Microsoft.KeyVault(...)` reference string regardless of runtime resolution. `/auth/me` returns a clean `401 Not signed in` (proves the app process and session middleware run, not DB connectivity — that path doesn't touch the DB). Real proof needs either a completed login (blocked on the Google OAuth redirect URI not yet being registered for the new `/api/auth/callback` path) or a direct schema/connection check against Neon.

## Spec Change Log

- **User-directed scope change (2026-08-21), mid-implementation, after the first 6 tasks shipped.** User: "container_registry אחד ישמש עבור שני הסביבות בענן — prod + stage. אותו הדבר עם Key Vault... תוסיף את Key Vault עכשיו ל-terraform. נתחיל להשתמש בו מיידית." (one ACR and one Key Vault shared across prod+stage; add Key Vault now, start using it immediately). This reverses the frozen "No Key Vault in this slice" boundary and the "Never: ...or Key Vault" line — both amended above. ACR moved out of `newsagent-stage-rg` into a new `newsagent-shared-rg` alongside the new Key Vault, renamed `newsagentacr` (verified globally available via `az acr check-name`) since it's no longer stage-specific. Also updated: `deferred-work.md`'s original Key Vault entry (marked superseded, not deleted) and a new deferred entry for tightening vault-level RBAC to per-secret once prod secrets actually land in the shared vault.

## Design Notes

Stage-only scope excludes the Function/tag-file/prod pieces (logged in `deferred-work.md`) — this slice's job is proving the container path end to end, with one manual command standing in for the automation that comes next.

ACR and Key Vault live in a separate `newsagent-shared-rg` rather than `newsagent-stage-rg` specifically so the not-yet-built prod slice can point at the same two resources instead of duplicating them — this is the user's explicit design (2026-08-21), not this spec inventing shared infrastructure speculatively.

## Verification

**Commands:**
- `terraform -chdir=terraform init && terraform -chdir=terraform plan` -- expected: clean plan, no errors; reviewed before apply
- `terraform -chdir=terraform apply` -- only after explicit approval of the plan output
- `curl https://newsagent-api-stage.azurewebsites.net/health` -- expected: `{"status":"ok"}` once a real image is set
- ~~`az webapp config appsettings list --name newsagent-api-stage --resource-group newsagent-stage-rg` -- expected: `NEWSAGENT_DATABASE_URL` etc. show as resolved Key Vault references, not raw `@Microsoft.KeyVault(...)` strings, once RBAC has propagated~~ -- **wrong command, discovered 2026-08-23:** this control-plane API always echoes the configured `@Microsoft.KeyVault(SecretUri=...)` string verbatim; resolution happens inside the container's runtime environment, not visible here. Real verification needs an app-level check that actually touches the secret (a working login, a DB-dependent endpoint, or Kudu's resolved-env view) -- not yet done, see AC4 above.

**Status as of 2026-08-21 (session end, resuming after Shabbat):**
- `terraform apply` ran successfully — all 15 resources live (verified via `terraform state list` + `az webapp show`, not just plan output). One real bug hit and fixed along the way: RBAC-mode Key Vault doesn't auto-grant the deployer secret access from creating the vault alone — needed an explicit `azurerm_role_assignment` + a `time_sleep` for propagation (see `main.tf` comments, resources `deployer_kv_access` / `wait_for_deployer_kv_rbac`).
- Both stage App Services are up at the platform level (`state: Running`) but still serving the generic placeholder image — expected, not a bug, since no real image has been pushed yet.
- **PR open, awaiting Naomi:** [news-agent#56](https://github.com/MONS-Designers/news-agent/pull/56) — adds the 2 Dockerfiles + `nginx.frontend.conf` + `docker-build-push.yml` to her repo. Needs her review/merge, then the 3 Azure secrets added to that repo's Actions settings (values are in the PR body — they're identifiers, not credentials).
- **Remaining before this spec is actually done:** Naomi merges #56 -> her CI pushes real images to `newsagentacr` -> manually point both stage App Services at the real tags (`az webapp config container set`, commands in `deploy/for-naomi/README.md`) -> optionally set real Key Vault secret values (same README) -> re-verify `/health` and the frontend for real. None of this can happen without Naomi's action first.

**Later same day, outside this spec's own scope (see `deferred-work.md` and the `project_gitops_rollout_plan` memory for full detail):** the old `newsagent-rg` VM was deleted (user's call — it wasn't working, nothing there was Terraform-managed), and a prod environment was built as an exact Terraform mirror of stage (`newsagent-prod-rg`, `newsagent-api-prod`, `newsagent-frontend-prod`, its own 4 Key Vault secrets in the same shared vault). Prod is in the identical "placeholder image, empty secrets" state stage started in — this spec's remaining acceptance criteria are still about stage only.

**Manual checks (if no CLI):**
- Open both stage App Services' default URLs in a browser after the manual image swap and confirm the real frontend/backend is served, not the placeholder.

**Status as of 2026-08-23 (stage fully live, 3/4 ACs confirmed):**
- [news-agent#56](https://github.com/MONS-Designers/news-agent/pull/56) merged. Its own CI run failed in 16s (missing repo secrets) -- not a code problem, just the one-time secrets setup not done yet at that point.
- Naomi added the 3 Actions secrets; the next CI run hit a second, unrelated failure: `AADSTS700213` during OIDC token exchange. Root cause -- GitHub rolled out immutable OIDC subject claims (2026-04-23 changelog) and `MONS-Designers/news-agent` is enrolled, so the subject now carries numeric org/repo IDs (`repo:MONS-Designers@174935491/news-agent@1302724286:ref:refs/heads/dev`), not the plain name format the federated identity credential was configured for. Fixed in `main.tf` (new `github_org`/`github_org_id`/`github_repo_name`/`github_repo_id` variables replacing the old single `github_repo` string), applied, confirmed via a manually re-dispatched run (`32657806182`, success) with both images landing in ACR.
- Before pointing stage at those images, found and fixed a design flaw in the handed-over frontend Dockerfile (outside this spec's original scope, but blocking it): `VITE_API_BASE` was baked into the image at build time, making the same tag non-promotable from stage to prod. Fixed via a relative `/api` fallback + nginx runtime reverse-proxy (`BACKEND_HOST` env var, envsubst'd at container start) -- shipped as [news-agent#58](https://github.com/MONS-Designers/news-agent/pull/58), merged. That PR also fixed an OAuth cookie-scoping bug the proxy design exposed in `auth.py` (`redirect_uri` was resolving off the proxy-rewritten `Host` header instead of `settings.frontend_url`).
- Real Key Vault secret values set via a gitignored `terraform/terraform.tfvars` (not `az keyvault secret set` directly, to avoid a future bare `terraform apply` silently reverting them to their empty defaults).
- Found and fixed a second infra gap while pointing stage at the real images: neither app could actually pull from `newsagentacr` (admin user is deliberately disabled; `frontend_stage`/`frontend_prod` had no identity at all, `api_stage`/`api_prod`'s identity had no `AcrPull`). Fixed for all 4 apps (stage + prod, matching the exact-mirror design) -- `container_registry_use_managed_identity = true` + an `AcrPull` role assignment per app. Required two Terraform applies (a brand-new `identity` block's `principal_id` isn't resolvable in the same plan as a new resource that references it).
- `az webapp config container set` run for `newsagent-api-stage` and `newsagent-frontend-stage` against the confirmed ACR tags. Verified live (see AC3 above).
- **Not yet done:** Google OAuth redirect URI registration in Google Cloud Console for `https://newsagent-frontend-stage.azurewebsites.net/api/auth/callback` (and the prod equivalent) -- without it, a real login attempt fails with `redirect_uri_mismatch`. This is what's blocking AC4's real proof and any actual end-to-end login test.
- Prod (`newsagent-api-prod`/`newsagent-frontend-prod`) still on the placeholder image and empty secrets -- same remaining steps as stage, not yet done, and outside this spec's own stage-only scope regardless.
