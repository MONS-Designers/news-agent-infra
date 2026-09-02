---
title: 'GitOps deploy trigger — stage and prod auto-deploy, with verified rollback'
type: 'feature'
created: '2026-09-02'
status: 'done'
review_loop_iteration: 0
baseline_commit: '7dd4d79051da5c6264e0317d40049759a09cb6c7'
context: [
  '{project-root}/_bmad-output/specs/spec-gitops-deploy-trigger/SPEC.md',
  '{project-root}/_bmad-output/specs/spec-gitops-deploy-trigger/pipeline-design.md',
]
---

<!-- Procedural note (not part of the template): the canonical, preservation-validated
     contract for this work is the SPEC.md + pipeline-design.md pair referenced in
     `context:` above — produced by the separate `bmad-spec` skill after a full grilling
     interview (see that spec's own `.memlog.md`), with "Open Questions: None outstanding."
     This tracking file intentionally does not re-derive that content; it exists to satisfy
     bmad-quick-dev's step-03/step-04 tracking conventions (baseline_commit, task list,
     status). status is set directly to ready-for-dev — skipping step-02's interactive
     CHECKPOINT 1 — because the plan was already reviewed end-to-end: the canonical spec
     itself, plus a separate advisor pass on the concrete implementation plan (file list,
     command syntax, ordering) that surfaced and resolved 6 correctness traps before any
     code was written. The task that invoked this skill run explicitly instructed
     implementing all 5 capabilities per the spec, which stands in for the checkpoint's
     approval. -->

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `news-agent`'s CI already builds and pushes images to `newsagentacr` on every push
to `dev`, but nothing updates the running App Services — stage sat pinned to a stale tag while
ACR held newer images, and prod has never received a real deploy at all.

**Approach:** Move the build→push→deploy pipeline into `news-agent-infra` (`deploy.yml`,
`repository_dispatch`-triggered from a minimal Action `news-agent` will add), dual-tag every
build (`<sha>` + a moving tag per environment), let Azure's `DOCKER_ENABLE_CI` app setting own
the ACR→App Service webhook (no explicit `az webapp config container set`), add a
`workflow_dispatch` rollback workflow doing server-side `az acr import` retags, and verify every
deploy/rollback against a `commit` field exposed by the running app rather than trusting a green
build. Full detail: `_bmad-output/specs/spec-gitops-deploy-trigger/SPEC.md`.

## Boundaries & Constraints

**Always:** Stage (`dev`) and prod (`main`) stay fully decoupled. Every build pushes both an
immutable `<sha>` tag and the environment's moving tag. Deploy verification polls the real
`commit` field (JSON, `jq`-parsed) every 5s up to 180s and fails loudly on timeout/mismatch — a
raw 200 is not success (nginx SPA fallback returns 200 for a missing `version.json`). No stored
Azure credential — OIDC only, except Credential F (PAT, out of this repo's control).

**Ask First:** Anything touching live Azure state (`terraform apply`) or `news-agent` itself
(commit/push/PR) — both explicitly deferred to the user, never done by this implementation pass.

**Never:** No Azure Function, no tag-file polling, no explicit `az webapp config container set`
step in the pipeline, no approval gate before deploy, no automatic rollback-on-failed-health.
Nothing in this repo's automation edits, commits, or pushes to `news-agent` — handoff files only,
under `deploy/for-naomi/`.

</frozen-after-approval>

## Code Map

- `.github/workflows/deploy.yml` -- NEW: build+push+verify pipeline (CAP-1/2/4/5)
- `.github/workflows/rollback.yml` -- NEW: workflow_dispatch retag + verify (CAP-3/5)
- `deploy/verify-commit.sh` -- NEW: shared poll-and-verify helper used by both workflows above
- `deploy/resolve-rollback-sha.sh` -- NEW: resolves target SHA for rollback (explicit or "one step back")
- `terraform/main.tf` -- EDIT: re-point Credential A's OIDC subject; add `DOCKER_ENABLE_CI`; switch 4 App Services off the placeholder image onto real ACR moving-tag images
- `terraform/variables.tf` -- EDIT: `github_repo_name`/`github_repo_id`/`github_branch` now describe `news-agent-infra` itself, not `news-agent`; drop now-unused `placeholder_image`/`placeholder_registry_url`
- `deploy/for-naomi/Dockerfile.backend` -- EDIT (handoff): add `GIT_SHA` build-arg baked into `deploy` stage
- `deploy/for-naomi/Dockerfile.frontend` -- EDIT (handoff): add `GIT_SHA` build-arg, write static `version.json`
- `deploy/for-naomi/trigger-deploy.yml` -- NEW (handoff): minimal Action firing `repository_dispatch`, replaces `docker-build-push.yml`
- `deploy/for-naomi/docker-build-push.yml` -- REMOVE (handoff): superseded, instructions to delete land in README
- `deploy/for-naomi/README.md` -- EDIT (handoff): new file table, deletion instructions (old workflow + 3 Azure secrets), `INFRA_DISPATCH_TOKEN` setup, `/health` diff snippet, corrected bootstrap-ordering instructions

## Tasks & Acceptance

**Execution:**
- [x] `terraform/variables.tf` -- repoint `github_repo_name`/`_repo_id`/`_branch` at news-agent-infra's own main; drop placeholder vars -- Credential A must trust this repo's own OIDC subject now that the pipeline runs here
- [x] `terraform/main.tf` -- update federated identity `subject`; add `DOCKER_ENABLE_CI="true"` + real ACR moving-tag `application_stack` to all 4 `azurerm_linux_web_app` resources -- required for the webhook mechanism to attach to ACR at all
- [x] `deploy/verify-commit.sh` -- poll a JSON URL for `.commit == expected`, 5s/180s, jq-based -- shared CAP-5 verification, avoids SPA-fallback false positive
- [x] `deploy/resolve-rollback-sha.sh` -- resolve explicit-or-previous SHA for a repo+moving-tag -- CAP-3 "one step back" logic, kept out of the workflow YAML for testability/readability
- [x] `.github/workflows/deploy.yml` -- build both images from a fresh `news-agent` checkout, push `<sha>`+moving tag, verify both apps -- CAP-1/2/4/5
- [x] `.github/workflows/rollback.yml` -- `az acr import --force` retag (per selected service), verify -- CAP-3/5
- [x] `deploy/for-naomi/Dockerfile.backend` -- add `ARG GIT_SHA=unknown` / `ENV GIT_SHA` in `deploy` stage -- CAP-5 backend source
- [x] `deploy/for-naomi/Dockerfile.frontend` -- add `ARG GIT_SHA=unknown`, write `version.json` in `serve` stage -- CAP-5 frontend source
- [x] `deploy/for-naomi/trigger-deploy.yml` -- push→`repository_dispatch` on `dev`/`main`, mapped to stage/prod -- CAP-4 handoff half
- [x] `deploy/for-naomi/README.md` -- rewrite for the new flow, explicit deletions, PAT/secret setup, bootstrap ordering -- keeps the handoff accurate, not half-updated
- [x] Remove `deploy/for-naomi/docker-build-push.yml` -- superseded by `trigger-deploy.yml`, per the spec's explicit "removed, not left dormant" constraint
- [x] `deploy/for-naomi/health-endpoint-diff.md` -- NEW (not originally listed): `/health` handed over as a snippet, not a whole-file replacement, since `main.py` is Naomi's living code (advisor guidance)

**Acceptance Criteria:**
- Given `deploy.yml` fires via `repository_dispatch` with `environment=stage`, when the build succeeds, then it pushes `newsagent-api:<sha>`+`stage-latest` and `newsagent-frontend:<sha>`+`stage-latest`, then polls `newsagent-api-stage`'s `/health` and `newsagent-frontend-stage`'s `/version.json` until `commit == <sha>` or fails loudly at 180s
- Given a `dev`-only push, when prod's pipeline never fires, then `newsagent-api-prod`'s reported commit is unchanged (decoupling)
- Given `rollback.yml` is run with `service=api,environment=stage,sha=<X>`, when the run completes, then `newsagent-api:stage-latest` in ACR is retagged to digest of `<X>` and `/health` reports `<X>`
- Given `rollback.yml` is run with no `sha`, when resolution runs, then it retags to the SHA-tagged manifest immediately before the one currently backing the moving tag, not the moving tag's own current SHA
- Given `version.json` is missing/unreachable, when `verify-commit.sh` polls it, then a raw HTTP 200 (nginx SPA fallback) is never accepted as a match — only a JSON body with the expected `commit` passes

## Design Notes

`az acr import`'s same-registry retag needs `--name <target-registry>` (the required flag) with
a fully-qualified `--source` (registry hostname included) — verified against installed `az` CLI
2.89.1 help output, since `pipeline-design.md`'s own illustrative command line omits `--name` and
would fail as written; the implementation uses the corrected, verified form.

Bootstrap ordering went through two drafts. First draft (build-first, then `terraform apply`)
was wrong and caught by a second advisor pass: `deploy.yml`'s OIDC login can't succeed until the
federated identity is already re-pointed at `news-agent-infra`'s own `main` -- which *is* the
`terraform apply` step -- so build-first is circular. Correct order (in
`deploy/for-naomi/README.md`): merge workflows to `news-agent-infra` main -> add the 3 Azure
secrets to `news-agent-infra` itself (previously only existed in `news-agent`, a gap the first
draft also missed) -> land Naomi's handoff on both `dev` and `main` -> `terraform apply` -> first
real bootstrap build -> create `INFRA_DISPATCH_TOKEN`.

Resolved post-review: `pipeline-design.md`'s claim that Credential A's `AcrPush` role covers
`az acr import` (rollback) was confirmed wrong -- `az role definition list -n AcrPush` shows only
`pull/read`/`push/write`; Microsoft's docs require `Container Registry Data Importer and Data
Reader` for same-registry import. Fixed via a new `azurerm_role_assignment.ci_acr_import` in
`terraform/main.tf`, same identity, same ACR scope. `CLAUDE.md`'s old smoke-test-after-every-deploy
rule was also removed by the user (`news-agent-infra/CLAUDE.md`), superseded by CAP-5's automated
verification for the auto-deploy path.

## Verification

**Commands:**
- `terraform -chdir=terraform fmt -check` -- expected: no formatting diff on edited files
- `terraform -chdir=terraform validate` -- expected: valid, once a backend/provider init succeeds (not run here — no state-changing init without approval; syntax reviewed manually if init is unavailable)
- `bash -n deploy/verify-commit.sh && bash -n deploy/resolve-rollback-sha.sh` -- expected: no syntax errors
- `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"` -- expected: both new workflow files parse as valid YAML

**Manual checks (if no CLI):**
- Diff `deploy/for-naomi/Dockerfile.backend`/`Dockerfile.frontend` against the real current `news-agent` `dev`-branch content (already fetched via `gh api` for this pass) to confirm the handoff is a clean, minimal diff, not a guess

## Suggested Review Order

**Deploy pipeline (CAP-1/2/4/5)**

- Entry point: what triggers a deploy and how the environment/SHA are resolved and validated.
  [`deploy.yml:16`](../../.github/workflows/deploy.yml#L16)

- Cross-repo checkout of `news-agent` at the triggering SHA, then a from-scratch image build.
  [`deploy.yml:58`](../../.github/workflows/deploy.yml#L58)

- Backend built, pushed, and verified before frontend starts — a later failure can't leave an already-pushed service unverified.
  [`deploy.yml:122`](../../.github/workflows/deploy.yml#L122)

- CAP-5 verification: JSON-parsed poll, not a raw HTTP status, so an nginx SPA-fallback 200 can't fake success.
  [`deploy.yml:134`](../../.github/workflows/deploy.yml#L134)

**Rollback (CAP-3)**

- Entry point: `service`/`environment`/optional `sha` inputs and the fail-fast `both` behavior.
  [`rollback.yml:19`](../../.github/workflows/rollback.yml#L19)

- Free-text `sha` input routed through `env:` rather than interpolated into the script directly (injection hardening).
  [`rollback.yml:95`](../../.github/workflows/rollback.yml#L95)

- Server-side retag via `az acr import --name ... --force` — corrected from `pipeline-design.md`'s illustrative command, which omits the required `--name`.
  [`rollback.yml:100`](../../.github/workflows/rollback.yml#L100)

**Shared verification/resolution scripts**

- Poll-and-verify: fails fast on an empty target SHA, bounds each request with `--max-time` so one hung connection can't blow the 180s budget.
  [`verify-commit.sh:29`](../../deploy/verify-commit.sh#L29)

- "One step back" resolution via ACR manifest metadata — ordering assumption called out explicitly as unverified.
  [`resolve-rollback-sha.sh:64`](../../deploy/resolve-rollback-sha.sh#L64)

**Terraform: OIDC re-point + auto-deploy webhook**

- Federated identity subject re-pointed from `news-agent`'s `dev` to this repo's own `main` — `name` deliberately left unchanged to avoid a destroy/recreate.
  [`main.tf:178`](../../terraform/main.tf#L178)

- `DOCKER_ENABLE_CI` is the entire deploy mechanism — Azure owns the ACR webhook from here, no explicit container-set step anywhere in this diff.
  [`main.tf:258`](../../terraform/main.tf#L258)

- App Service `application_stack` switched from the placeholder image to the real ACR moving-tag image (bootstrap-ordering-sensitive — see README).
  [`main.tf:233`](../../terraform/main.tf#L233)

**news-agent handoff (never committed to news-agent directly — files only)**

- `GIT_SHA` baked in at build time, source for `/health`'s `commit` field.
  [`Dockerfile.backend:54`](../../deploy/for-naomi/Dockerfile.backend#L54)

- `version.json` written into the build stage's `dist/` (avoids any serve-stage non-root write-permission question).
  [`Dockerfile.frontend:32`](../../deploy/for-naomi/Dockerfile.frontend#L32)

- Minimal trigger Action — the only file that actually replaces `docker-build-push.yml`'s role in `news-agent`.
  [`trigger-deploy.yml:32`](../../deploy/for-naomi/trigger-deploy.yml#L32)

- `/health` handed over as a snippet, not a whole-file replacement, since `main.py` is Naomi's living code.
  [`health-endpoint-diff.md:33`](../../deploy/for-naomi/health-endpoint-diff.md#L33)

- Corrected bootstrap ordering (an earlier draft was circular — OIDC login can't succeed before the identity it re-points is applied).
  [`README.md:38`](../../deploy/for-naomi/README.md#L38)

- Two open items flagged for Moshe, not resolved unilaterally: the `AcrPush`/`az acr import` permission gap, and full automation vs. this repo's own `CLAUDE.md` smoke-test rule.
  [`README.md:100`](../../deploy/for-naomi/README.md#L100)
