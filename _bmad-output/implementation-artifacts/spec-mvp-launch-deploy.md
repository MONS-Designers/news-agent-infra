---
title: 'MVP launch — Azure production deploy'
type: 'chore'
created: '2026-08-12'
status: 'in-progress'
review_loop_iteration: 0
context: []
baseline_commit: 'e08ed60913e064cef9b5e277baf6a4656736b600'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** NewsAgent's MVP is fully built on `news-agent`@`dev` but nothing is deployed — no
production VM, no DNS, no seeded data — so the 2 seeded dogfood users can't receive a digest.

**Approach:** Execute the already-decided plan (Azure VM via `az` CLI, app./api. subdomain
split, Gmail SMTP): provision the VM, point DNS at it, run the existing provisioning script,
seed production data, and verify one end-to-end digest send — gated by the human-only blockers
(PR #47 merge, Google OAuth Console, SMTP confirmation) already identified in the plan doc.

## Boundaries & Constraints

**Always:**
- Follow the locked decisions in `_bmad-output/implementation-artifacts/mvp-launch-deploy-plan.md`
  verbatim (subscription "Azure for Students", israelcentral, `Standard_B2s_v2`, `az` CLI not
  Terraform, app./api. subdomain split, Gmail SMTP, source list reconciled via admin UI not code).
- Re-verify live state (resource existence, DNS resolution, provider registration) immediately
  before any state-changing command — it drifts between sessions.
- Never commit secrets; filled `deploy/.env` stays untracked, chmod 600 on the VM.
- Interact with the sibling `news-agent` repo read-only only (no local edits, no commands run
  against it) — the VM clones it fresh via `provision-vm.sh`.

**Ask First:**
- `az vm create` (billable resource).
- Any DNS record change (no Cloudflare CLI/API access on this machine — human executes in the
  dashboard; agent supplies the exact record values).
- Running `deploy/provision-vm.sh` on the VM (installs packages, opens nginx to 80/443, requests
  certbot TLS certs, starts systemd services).
- Seeding production data (`add-admin`, `seed-sources`, `seed-fields`, `seed-roles`) — admin
  emails are a decision, not a default.
- Anything touching PR #47, the Google OAuth Console, or the SMTP account — human-owned per the
  plan doc; agent reports status, does not act.

**Never:**
- Terraform migration; full-text extraction / topic-diversity floor (Epic D); click-tracking /
  engagement dashboard (Story B.2) — all explicitly deferred in the plan doc.
- Editing or running commands against the sibling `news-agent` repo's local checkout.
- Auto-merging PR #47, editing the Google OAuth Console, or deciding unilaterally that the SMTP
  account is production-ready.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| VM name collision | `az vm create` re-run against existing NSG/VNET/PublicIP/NIC | Slots into existing networking resources without erroring | If it errors on collision, investigate before deleting anything |
| DNS not yet propagated | `provision-vm.sh` reaches certbot before A records resolve | certbot fails to issue cert | HALT, wait for propagation, re-run script (idempotent-ish) |
| Missing `.env` on VM | `provision-vm.sh` step 4 | Script exits 1 with explicit message | Copy filled `deploy/.env.example` to VM as `news-agent/.env`, chmod 600, re-run |
| `news-agent-infra/deploy/` absent on VM | `provision-vm.sh` steps 6 & 8 (`cp /opt/newsagent/news-agent-infra/deploy/...`) | `cp` fails, script aborts (gap found during investigation — nothing currently populates this path) | scp this repo's `deploy/` dir to `/opt/newsagent/news-agent-infra/deploy/` on the VM before running the script |
| PR #47 still open | Subdomain split live, session-cookie domain not configured | Login won't survive the cross-subdomain request | Confirm PR #47 merged before E2E OAuth verification; flag to Naomi if still open |

</frozen-after-approval>

## Code Map

- `deploy/provision-vm.sh` -- provisioning script run on the VM; has a real gap (references
  `/opt/newsagent/news-agent-infra/deploy/` which nothing currently populates)
- `deploy/.env.example` -- template for the real `.env`, filled locally then copied to the VM
- `deploy/nginx.conf` -- reverse proxy config for the app./api. subdomain split, sed-templated
  by the script
- `deploy/newsagent-pipeline-daily.{service,timer}` -- daily fetch/filter/summarize units
- `deploy/newsagent-digest-weekly.{service,timer}` -- weekly build-digests/send-digests units
  (timer's schedule is explicitly flagged as a placeholder product decision, not infra)
- `sources/default_sources.yaml` -- this repo's 10-source list (4 tech, 3 world_news, 3 science),
  reconciled into the admin UI post-seed per the locked decision
- `_bmad-output/implementation-artifacts/mvp-launch-deploy-plan.md` -- source intent, locked
  decisions, live-state notes

## Tasks & Acceptance

**Execution:**
- [x] `az vm create` -- created `newsagent-vm` in `newsagent-rg`/israelcentral, Ubuntu 24.04,
  `Standard_B2s_v2`, reusing the existing free NIC (`--nics newsagent-vmVMNic`) -- public IP
  `20.217.24.140`. Also added NSG rules for ports 80/443 (not in original plan -- VM create only
  opens 22 by default; nginx/certbot need 80/443 inbound).
- [x] Cloudflare -- A records for `app.newsagent-ai.com` and `api.newsagent-ai.com` →
  `20.217.24.140`, DNS-only (not proxied). Done via Cloudflare API (user provided
  `CLOUDFLARE_API_TOKEN` via a local file) rather than the dashboard originally assumed.
- [x] `deploy/.env` (local, untracked, chmod 600) -- filled via an `awk` merge of
  `deploy/.env.example` + secrets already in `news-agent`'s local `.env`, plus production
  overrides (FRONTEND_URL, BACKEND_BASE_URL, SESSION_COOKIE_DOMAIN, SMTP sender). Values never
  printed to chat or logs.
- [x] scp `deploy/.env` and this repo's `deploy/` dir → VM staging path, then `sudo`-moved into
  `/opt/newsagent/news-agent/.env` and `/opt/newsagent/news-agent-infra/deploy/` -- closes the
  script gap noted above. Two-pass sequence: pass 1 (packages/clone) stops at the `.env` check
  by design, files get placed, pass 2 completes the rest.
- [x] Fixed `provision-vm.sh`: certbot's `-m` flag had a hardcoded, never-replaced
  `REPLACE_WITH_ADMIN_EMAIL` -- now uses `$ADMIN_EMAIL` (moisi6510@gmail.com). Also fixed apt's
  `nodejs` (v18 on Ubuntu 24.04) failing the frontend build (`@tailwindcss/oxide` needs >=20) --
  now installs Node 20 via NodeSource.
- [x] Ran `deploy/provision-vm.sh` on the VM (SSH) -- packages, clone, venv, migrations, frontend
  build, systemd units, nginx, certbot all completed. `newsagent-api` and `nginx` active,
  both timers scheduled, `https://api.newsagent-ai.com/health` → 200, `https://app.newsagent-ai.com/` → 200, valid TLS.
- [x] Fixed a post-deploy correctness bug: `deploy/.env.example`'s inline `KEY=value  # comment`
  style is invalid for a systemd `EnvironmentFile` (only a leading `#` is treated as a comment;
  `NEWSAGENT_EMAIL_SENDER=smtp  # console | smtp` would have loaded with the comment attached,
  silently falling back to console-only email — service healthy, digests never sent). Moved all
  inline comments in the template to standalone lines, fixed the deployed `.env`, restarted
  `newsagent-api`. Confirmed `NEWSAGENT_RELEVANCE_THRESHOLD` (absent from prod `.env`) has a safe
  default (`0.7`) in the deployed `config.py`, so no fix needed there.
- [x] Seed data on the VM -- admins `moisi6510@gmail.com` + `nomimagnus@gmail.com` created;
  `seed-sources` (3 topics, 8 sources), `seed-fields` (5), `seed-roles` (20) all ran clean.
- [x] **Redeploy 2026-08-16**: PR #47 merged, pulled latest `news-agent`@`dev` (15 commits: CORS
  + session-cookie-domain, Hebrew RTL frontend, article full-text extraction, engagement
  tracking, and a DB default switch from SQLite to Postgres). Updated `deploy/.env` with the
  rotated SMTP password and a new `NEWSAGENT_DATABASE_URL` (Neon-hosted Postgres, provided by
  Naomi). Found and fixed an invisible Unicode mark in the pasted connection string that broke
  psycopg's parsing. Found the target Postgres DB already held Naomi's own dev/test data (14
  topics incl. fashion/toy-industry test topics, 309 articles, only her own admin/user) --
  backed it up to `_bmad-output/implementation-artifacts/neon_backup_pre_wipe_2026-08-16.json`,
  then wiped and re-seeded per explicit user decision. Frontend rebuilt, `newsagent-api`
  restarted. Fresh DB confirmed: 2 admins, 3 topics, 8 sources, 5 fields, 20 roles, 0 users/articles.
- [ ] Reconcile source list via admin UI -- now unblocked (PR #47 merged); not yet done.
- [ ] E2E verification -- now unblocked pending confirmation the Google OAuth Console redirect
  URI is registered; not yet attempted.

**Acceptance Criteria:**
- Given the existing NSG/VNET/PublicIP/NIC in `newsagent-rg`, when `az vm create` runs, then
  `newsagent-vm` exists with a public IP and SSH access succeeds.
- Given DNS resolves to the VM IP and a filled `.env` is in place, when `provision-vm.sh`
  completes, then `newsagent-api` and `nginx` are both active and `https://api.newsagent-ai.com/health`
  returns 200 over valid TLS.
- Given systemd timers are enabled, when checked, then `newsagent-pipeline-daily.timer` and
  `newsagent-digest-weekly.timer` both show active/enabled.
- Given seeding has run and PR #47 is merged, when a manual pipeline run
  (fetch→filter→summarize→build-digests→send-digests) is triggered, then one of the 2 seeded
  dogfood users receives a real digest email.
- Given PR #47 is still open, when E2E OAuth login is attempted, then failure is expected — a
  known, already-flagged blocker, not a new bug to chase.

## Spec Change Log

## Design Notes

The `provision-vm.sh` gap (steps 6 & 8 `cp` from `/opt/newsagent/news-agent-infra/deploy/`,
which no step populates) is fixed by adding an scp of this repo's `deploy/` dir to that exact
path before running the script — not by rewriting the script to `git clone` this repo, since
that would need extra VM-side auth for a private repo for a one-time, 7-file copy.

## Verification

**Commands:**
- `az vm show -g newsagent-rg -n newsagent-vm -d -o table` -- expected: VM exists, running, public IP assigned
- `dig +short app.newsagent-ai.com` / `dig +short api.newsagent-ai.com` -- expected: both resolve to the VM's public IP
- `ssh newsagent-admin@<vm-ip> systemctl is-active newsagent-api nginx` -- expected: both `active`
- `curl -sI https://api.newsagent-ai.com/health` -- expected: `200`
- `ssh newsagent-admin@<vm-ip> systemctl list-timers` -- expected: both digest timers listed, enabled

**Manual checks (if no CLI):**
- Confirm a real digest email arrives in a seeded dogfood user's inbox (no automated delivery check)
- Confirm `https://app.newsagent-ai.com/admin` loads and shows the reconciled source list
