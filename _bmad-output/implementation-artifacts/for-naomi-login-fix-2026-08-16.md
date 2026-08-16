# For Naomi — login fix + what happened

Short version: the deployed site's login is broken because of a gap between an infra decision
and a frontend assumption that nobody checked against each other. Here's the exact fix needed
on your side, what's already done on mine, and an honest accounting of what this cost.

## 1. The fix needed in `news-agent`

`frontend/src/api/client.ts` hardcodes:

```ts
const API_BASE = "/api";
```

This only resolves correctly when the frontend and backend share an origin. The deployed site
splits them across `app.newsagent-ai.com` (static frontend) and `api.newsagent-ai.com`
(backend) — so every `/api/*` call, including the login button, silently resolves against the
frontend's own static-file host instead of the backend. nginx's SPA fallback returns the
app shell with a `200` for these paths instead of an error, so it looks like nothing happens
when the login button is clicked — no console error, no failed network request.

The fix is one line, and it uses the env var name you'd already declared in
`frontend/.env.example` (`VITE_API_BASE=http://localhost:8000`) but never actually wired up:

```ts
const API_BASE = import.meta.env.VITE_API_BASE ?? "/api";
```

That's the whole change. Local dev keeps working exactly as-is (falls back to `/api`, which
Vite's dev-server proxy already strips and forwards to `127.0.0.1:8000`). Nothing else in
`client.ts` needs to change — every call already goes through this one constant.

## 2. What's already done on the infra side

- `deploy/provision-vm.sh` now builds the frontend with
  `VITE_API_BASE=https://api.newsagent-ai.com` set, so once your change lands, a redeploy picks
  it up automatically — no further coordination needed on that step.
- Added a **Cross-repo integration** section to `news-agent/CLAUDE.md` (your repo) and the
  equivalent in `news-agent-infra/CLAUDE.md` (mine): before either of us locks in something
  that assumes a particular deployment shape (API base URL, cookie domain, CORS origins,
  router paths), we trace the actual interaction on both sides first, or just ask each other —
  a two-line message before locking in beats discovering the gap after a deploy.
- Added `deploy/smoke_test.py` (stdlib-only) + a scheduled GitHub Actions job in
  `news-agent-infra` that checks the live login redirect actually reaches Google, not just that
  something returns `200`. This is the exact check that would have caught this before either of
  us found out about it via a failed manual test.

Full root-cause writeup: `_bmad-output/implementation-artifacts/retro-mvp-deploy-2026-08-16.md`
(in `news-agent-infra`).

## 3. What this cost — an honest accounting

**Your data:** the production Postgres DB (Neon) you gave me the connection string for wasn't
empty — it had your own dev/test data (1 admin, 2 users, 14 topics including your
fashion/toy-industry test topics, 17 sources, 309 articles, 4 digests). I found this before
writing anything, backed the whole thing up to
`_bmad-output/implementation-artifacts/neon_backup_pre_wipe_2026-08-16.json` (fully
recoverable), then wiped and reseeded it with the MVP's real topics/sources — but that decision
was made between me and Moshe, not with you. If any of that data mattered to you, it's sitting
in that JSON file, not gone.

**Time:** three separate deploy passes since PR #47 merged — an initial SQLite deploy (which
hit and fixed three unrelated bugs: an outdated Node version breaking the frontend build, an
unreplaced certbot placeholder, a systemd config bug that would have silently disabled email
sending), a full redeploy after the Postgres switch (a corrupted connection string, the DB
state surprise above), and then this login investigation — which only started because a manual
click-through finally exercised the one path none of the automated checks covered. I don't have
precise hours, but it's a multi-day, multi-cycle cost that a single cross-check earlier would
have avoided entirely.

**Root cause — not one-sided:** your `/api` default was a completely reasonable choice for a
codebase that had never been deployed anywhere but localhost. The subdomain-split decision on
my side was made by checking only the backend's router prefixes, never your actual frontend
code. Neither assumption was wrong in isolation; nobody's job was to check them against each
other before they met in a real deployment. That's the actual gap — process, not a mistake
either of us made carelessly — and it's what the CLAUDE.md additions above are meant to close.
