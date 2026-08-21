- source_spec: `_bmad-output/implementation-artifacts/spec-default-rss-sources.md`
  summary: Add a closed vocabulary/allow-list for the `language` field (e.g. ISO 639-1 codes), analogous to `ALLOWED_CATEGORIES`.
  evidence: Currently any non-empty string passes (e.g. "english", "EN", a typo) — surfaced by both review passes as an inconsistency with how `category` is validated. Not required by the current spec, which only asked for non-empty-string presence.

- source_spec: `_bmad-output/implementation-artifacts/spec-default-rss-sources.md`
  summary: Pin dependency versions in `requirements.txt` (or add a lockfile) once this repo's tooling stabilizes.
  evidence: Blind Hunter review flagged unpinned `pyyaml`/`pytest` as a reproducibility risk; out of scope for a first, minimal `requirements.txt`.

- source_spec: `_bmad-output/implementation-artifacts/spec-default-rss-sources.md`
  summary: Wire `sources/validate_sources.py` into CI or a pre-commit hook so it runs automatically on every edit to `default_sources.yaml`.
  evidence: Right now the validator only protects the file if a human remembers to run it by hand. This repo has no CI/pre-commit setup yet at all, so adding one is a separate, larger task.

- source_spec: `_bmad-output/implementation-artifacts/spec-default-rss-sources.md`
  summary: Give a clearer validator error message when a YAML value is implicitly coerced to a bool by the parser (e.g. `language: no` → Python `False`), instead of the generic "missing or empty" message.
  evidence: Confirmed via reproduction during review. The current behavior is safe (validation still fails) but the message doesn't hint at the YAML type-coercion footgun, which could send a debugging admin down the wrong path.

- source_spec: `_bmad-output/implementation-artifacts/spec-default-rss-sources.md`
  summary: Before sources are used to redistribute translated summaries to end users (not just personal RSS reading), have a human check each outlet's syndication/ToS terms — flagged specifically for NYT, which is paywalled.
  evidence: Blind Hunter review raised this; it's a business/legal judgment call for whoever defines the admin's source-approval criteria, not something a data-validation script can or should decide. The admin-approval step this list feeds into (per news-agent's design) is the natural place to apply it.

- source_spec: `_bmad-output/implementation-artifacts/spec-mvp-launch-deploy.md`
  summary: Move production secrets from a scp'd `.env` file on the VM to Azure Key Vault + VM Managed Identity, with `provision-vm.sh` pulling secrets at deploy time instead of receiving a copied file.
  evidence: User raised this during launch deploy; explicitly deferred to keep this MVP pass to the already-locked plan (scp + chmod 600 + service-user ownership). Worth doing once this is a real production system past the 2-dogfood-user stage — adds one Azure resource (Key Vault) and a Managed Identity, no app code changes needed since news-agent still just reads a local `.env`.
  superseded: Partially actioned 2026-08-21 — the user un-deferred Key Vault for the App Service migration (`spec-stage-deploy-baseline.md`), shared across stage/prod, wired via App Service Key Vault references (not a VM Managed Identity, since the VM is being replaced, not kept). The VM-specific half of this entry (provision-vm.sh pulling secrets) no longer applies if/when the VM is decommissioned — see the prod-cutover entry below.

- source_spec: none
  summary: Per-environment Key Vault secret isolation — right now the stage App Service's managed identity gets vault-level `Key Vault Secrets User`, which is broader than it needs once prod secrets land in the same shared vault (it could technically read prod secrets too).
  evidence: Split out of the stage Key Vault work (2026-08-21) — harmless today since no prod secrets exist yet in the shared vault, but must be tightened (e.g. per-secret RBAC scope, or separate vaults) before the prod slice actually stores real prod secrets there.

- source_spec: `_bmad-output/implementation-artifacts/spec-docker-image-build-ci.md`
  summary: Add a CI step that actually runs the built runtime image (docker run + poll /health) instead of only building it, so import/startup breakage is caught automatically rather than relying on manual local verification.
  evidence: Blind Hunter review: `docker-build.yml` only builds and scans; a future `news-agent@dev` commit that breaks the API import (renamed module, dropped dependency) would still produce a green CI run today. Out of scope for this spec, which explicitly limited CI to "build + scan only."

- source_spec: `_bmad-output/implementation-artifacts/spec-docker-image-build-ci.md`
  summary: Add `concurrency:` (cancel superseded runs) and a `paths:` filter (skip the build on changes that can't affect the image, e.g. docs/source-list edits) to `docker-build.yml`.
  evidence: Blind Hunter review: trigger is bare `push`/`pull_request` with no branch or path scoping, so rapid pushes queue up multiple full builds and unrelated changes (e.g. `sources/default_sources.yaml`) still trigger a full clone + npm ci + pip install + Trivy DB fetch.

- source_spec: `_bmad-output/implementation-artifacts/spec-docker-image-build-ci.md`
  summary: Upload Trivy's scan results as SARIF to GitHub's code-scanning/Security tab instead of only a job-log table, so findings are tracked and diffed across runs.
  evidence: Blind Hunter review: current `format: table` output is only visible as a log dump on failure and disappears once superseded by the next run — no historical record of what was found or when it was resolved.

- source_spec: `_bmad-output/implementation-artifacts/spec-docker-image-build-ci.md`
  summary: Pin `python:3.12-slim` and `node:20-slim` in `deploy/Dockerfile` to a digest (or add a Renovate/Dependabot config) once this repo has automated dependency-update tooling, for fully reproducible builds.
  evidence: Blind Hunter review flagged mutable-tag base images as a reproducibility risk (a rebuild days apart can silently pick up different content and different Trivy findings). `alpine/git` was pinned to `2.54.0` as part of this spec's review fixes since it was a trivial one-line change; the `-slim` tags were left as-is to match this repo's existing convention (`provision-vm.sh` doesn't pin exact package versions either) and because digest-pinning without update tooling just trades one staleness problem for another.

- source_spec: none
  summary: Open a PR to Naomi's `news-agent` repo adding a DB-connectivity readiness endpoint (e.g. `/healthz`) — the existing `/health` (`src/newsagent/api/main.py:35-37`) is a static liveness stub that returns `{"status": "ok"}` unconditionally with no DB check.
  evidence: Split out of the GitOps Azure deploy intent (2026-08-21) per the user's explicit choice: ship the GitOps pipeline now against the existing static `/health`, open the Naomi PR in the immediate next iteration. Cross-repo ask, different owner, not blocking the deploy pipeline itself.

- source_spec: none
  summary: Azure Function (Consumption plan, Timer trigger) that polls `image-tags-stage.yaml` / `image-tags-prod.yaml` (Credential C, read-only) and updates the matching App Service's container image (Credential D, system-assigned managed identity) when a tag changes. Must confirm the tag actually exists in ACR before applying it (user's own point, 2026-08-21) rather than trusting the file blindly — App Service would otherwise fail to pull a nonexistent tag.
  evidence: Split out of the GitOps Azure deploy intent (2026-08-21) — has nothing to poll or update until the stage App Services and tag files exist. Sequencing: build after slice 1 ships.

- source_spec: none
  summary: Prod environment Terraform (mirrors stage: 2nd pair of App Services, prod tag file) plus the prod cutover itself (decommissioning or repurposing the existing `newsagent-vm`).
  evidence: Split out of the GitOps Azure deploy intent (2026-08-21) — gated on the still-open batch-pipeline hosting decision (daily/weekly systemd timers have no direct App Service equivalent; Azure Container Instances is confirmed available in `israelcentral` via `az provider show -n Microsoft.ContainerInstance`, but the design itself — same image, different `CMD`, on a schedule — is not yet written). Cutting over prod before that's settled would strand the pipeline.
  superseded: Partially actioned 2026-08-21, same session. User: "the application wasn't working, no problem to delete" — `newsagent-rg` (the old VM + its networking) was deleted outright rather than decommissioned as part of a careful cutover; there was no real traffic/working app to migrate. The prod Terraform mirror (resource group, App Service Plan, 2 web apps, 4 Key Vault secrets, all on the placeholder image, same shape as stage) was also built and applied same session. What's still genuinely open: the batch-pipeline hosting decision (still unwritten — this remains true), and prod has no real images/secrets/deploy automation yet, same gaps as stage.
