# NewsAgent MVP — launch deploy plan (draft for bmad-quick-dev)

## Locked decisions (do not re-litigate — re-derive-and-verify if anything here
looks off against live state, per this repo's no-stale-counts rule, but these
were deliberately decided in conversation, not assumed)

- **Deploy target: `news-agent`'s `origin/dev` branch**, not `main` (`main` is a
  single-commit empty scaffold — all real functionality is on `dev`).
- **Hosting: Azure, subscription "Azure for Students"**, resource group
  `newsagent-rg` in `israelcentral` (lowest latency to the Hebrew-speaking,
  Israel-based target users). VM size `Standard_B2s_v2` — `Standard_B1s` has
  no current capacity in this region, `B2s_v2` does and is still cheap.
  Provisioning via plain `az` CLI, deliberately not Terraform (single VM,
  ~4 resources — IaC overhead doesn't pay off at this scale; revisit if the
  infra footprint grows).
- **Domain split: `app.newsagent-ai.com`** (Vue SPA, static) **/
  `api.newsagent-ai.com`** (FastAPI backend) — not one domain with path
  routing, because the backend's `/admin` router prefix (`/admin/sources`)
  collides with the frontend's `/admin` SPA page route; confirmed by reading
  `api/main.py`'s actual router mounts, not assumed from the (stale) README.
- **Email: SMTP via Naomi's existing `newsagent.ai.01@gmail.com`** Gmail
  account (app password already generated, already in `news-agent`'s local
  `.env` per the user). Rejected Beehiiv — its real per-recipient
  personalization API is beta + Enterprise-tier-gated (100k+ subscriber
  pricing); its group/segment model also doesn't map onto NewsAgent's
  per-user ranking (affinity is per-individual, not per-topic-set).
- **Self-hosted LLM (Nebius): deferred, not blocking.** If/when a cheap
  high-volume model gets self-hosted, it's an additive second node pointed at
  via the existing `LOCAL_LLM_BASE_URL` seam — not a migration off Azure.
- **Source lists: unify via the admin UI, not a code change.** Naomi's
  `seed-sources` CLI seeds her own hardcoded 8 sources (Topics: AI,
  Cybersecurity, Space). This repo's `sources/default_sources.yaml` (10
  sources; categories tech/world_news/science) is NOT wired into that seed
  path at all today. Plan: run `seed-sources` first, then add this repo's
  remaining 9 sources (skip "NASA Breaking News" — already seeded under
  Space, same URL) through the admin UI under new "Tech"/"World
  News"/"Science" topics. Don't hand-craft finer taxonomy granularity today.

## Still open / needs a human, not just an agent

- **PR #47** (`feat: CORS + configurable session-cookie domain for
  subdomain split`, https://github.com/MONS-Designers/news-agent/pull/47) —
  **OPEN, not merged.** CI is green. Needs Naomi's review/merge before the
  subdomain split can actually work in prod (without it, login won't survive
  the cross-subdomain request).
- **Google OAuth Console** (whoever owns the `google_client_id` project —
  probably Naomi, unconfirmed): add `https://api.newsagent-ai.com/auth/callback`
  as an authorized redirect URI, and publish the OAuth consent screen to
  Production (or add every friend as a manual test user) — self-registration
  is silently blocked by Google before the app's own code runs otherwise.
  Scopes are non-sensitive (`openid email profile`), so this should be a fast
  self-service toggle, not a review process.
- **Naomi confirmation on the SMTP account** — the user has the app password
  and it's in `.env`, but nobody has explicitly confirmed
  `newsagent.ai.01@gmail.com` is meant as the *production* sender vs. a
  placeholder. Cheap to confirm, expensive to discover wrong after go-live.

## Current live infra state (verify before acting — this drifts)

- Resource group `newsagent-rg` exists in `israelcentral`.
- Networking scaffolding already created and succeeded from prior failed VM
  attempts: `newsagent-vmNSG`, `newsagent-vmVNET`, `newsagent-vmPublicIP`,
  `newsagent-vmVMNic`. A VM-create retry should slot into these rather than
  erroring on name collision — if it does error, investigate before deleting
  anything.
- `Microsoft.Compute` and `Microsoft.Network` resource providers are now
  registered on the subscription (were the blocker on the 2nd VM attempt).
- No VM resource exists yet — both prior attempts failed before the VM
  itself was created (SKU capacity, then provider registration).
- `az` CLI is installed and logged in on this machine (`~/.azure`), as
  `moisi6510@gmail.com` — persists across sessions since it's disk-based, no
  re-login needed unless the token expires.

## Remaining work, roughly in dependency order

1. Retry VM creation: `az vm create --resource-group newsagent-rg --name
   newsagent-vm --image Ubuntu2404 --size Standard_B2s_v2 --admin-username
   newsagent-admin --ssh-key-values ~/.ssh/id_rsa.pub --public-ip-sku
   Standard`. Get the resulting public IP.
2. Add Cloudflare DNS: A records for `app.newsagent-ai.com` and
   `api.newsagent-ai.com` → that IP. (No Cloudflare CLI/API access from this
   machine as of this writing — check again, otherwise this needs to be done
   manually in the Cloudflare dashboard.)
3. Once DNS resolves: run `deploy/provision-vm.sh` (already written, in this
   repo) against the VM — installs packages, clones `news-agent`@`dev`,
   builds frontend, sets up systemd units + nginx + certbot TLS. Requires
   copying a filled `deploy/.env.example` to the VM as `news-agent/.env`
   first (real domain values, real secrets — chmod 600, never commit).
4. Seed data on the server: `add-admin` for whichever emails should have
   admin access, `seed-sources`, `seed-fields`, `seed-roles`, then reconcile
   this repo's source list per the decision above.
5. End-to-end verification: OAuth login actually completes (blocked until
   the Console steps above are done), admin can approve/view sources, a
   manual pipeline run (`fetch`→`filter`→`summarize`→`build-digests`→
   `send-digests`) produces a real received email.

## Explicitly NOT in scope for this pass

- Terraform migration (deliberately deferred, see decisions above).
- Full-text extraction / digest topic-diversity floor (Epic D — unbuilt in
  `news-agent`, user said "we need to come back for this").
- Click-tracking / engagement dashboard (Story B.2 — explicitly not required
  for B.1/launch per news-agent's own epic doc).
- Unsubscribe/CAN-SPAM compliance header — a real gap, flagged, not yet
  actioned; worth raising with Naomi alongside the SMTP/OAuth items.
