---
title: 'Retrospective — MVP deploy login failure'
date: '2026-08-16'
source_spec: '_bmad-output/implementation-artifacts/spec-mvp-launch-deploy.md'
---

# Retrospective: MVP deploy, OAuth login failure

## Summary

The MVP was deployed twice (once on SQLite, once redeployed onto Postgres after PR #47
merged) and both times reported "live and healthy" — VM up, TLS valid, `/health` returning
200, systemd services active. When the user actually tried to log in, nothing happened. The
root cause was a cross-repo integration gap that no health check could have caught: the
frontend hardcodes a relative API base URL (`/api`), which only resolves correctly if the
frontend and backend share an origin — but the infra side deployed them on split subdomains
(`app.*` / `api.*`) specifically to avoid a path collision that was never actually verified
against the frontend's real behavior.

Every verification step performed during deployment was real and passed. None of them
exercised the one interaction that was actually broken.

## Timeline

1. Locked decision (earlier session): split `app.*`/`api.*` subdomains, reasoning "backend's
   `/admin` router prefix collides with frontend's `/admin` SPA route — confirmed by reading
   `api/main.py`'s actual router mounts."
2. Deployed VM, DNS, provisioning — SQLite backend. Fixed three real bugs found along the way
   (Node 18→20, certbot's unreplaced placeholder email, a systemd `EnvironmentFile` inline-comment
   bug that would have silently disabled email sending). Reported deploy complete and verified.
3. PR #47 merged. Redeployed onto latest `dev`, which had switched to Postgres. Found and fixed
   an invisible Unicode character in a pasted connection string. Found the target Postgres DB
   already held Naomi's dev/test data; backed it up, wiped, reseeded. Reported redeploy complete.
4. User attempted login. Nothing happened.
5. Diagnosis: `frontend/src/api/client.ts` has `const API_BASE = "/api"` — a relative path,
   hardcoded since the very first frontend scaffold commit, with no env-based override. Every
   `/api/*` call — including the OAuth login kickoff — resolves against `app.newsagent-ai.com`,
   which serves only static files. nginx's SPA fallback (`try_files ... /index.html`) returns
   `index.html` with `200 OK` for these paths, so the failure is invisible at the HTTP-status
   level: no error, no 404, just the wrong document silently swapped in.

## Two lenses

### Infrastructure-side gap

The subdomain-split architecture decision was made by checking only **one side** of the
integration: the backend's router mounts (`api/main.py`). It was never checked against the
frontend's actual outgoing request code (`client.ts`). Reading the router prefixes told me
what paths the *backend* would accept; it told me nothing about what paths the *frontend*
would actually request. Those are independent facts, and I only verified one of them before
locking in an architecture that depends on both.

**The generalizable failure:** when an infra decision spans two codebases (or two halves of
one codebase) that are supposed to interoperate, checking one side's structure and reasoning
about the other side's likely behavior is not verification — it's assumption with extra
steps. The fix isn't "be more careful reading `main.py`" — it's **trace the actual
integration path end-to-end before locking the decision**: for a login-flow architecture
question, that means reading (or running) the actual button click through to the actual
outgoing request, not just the backend route table.

### Development-side gap

`API_BASE = "/api"` has been a hardcoded relative path since the frontend's original scaffold
commit. There is no environment variable, no build-time config, no override mechanism at all.
This isn't a regression — it was never designed for anything other than same-origin serving
(the assumption that made sense for local dev, where Vite's dev server or a same-origin prod
setup makes a relative path just work).

**The generalizable failure:** an external-service base URL (API host, in this case) is
exactly the kind of value that differs between local dev and every real deployment shape. When
that value is hardcoded rather than configurable from day one, the frontend silently commits
the *whole application* to one specific deployment topology (same-origin) without that ever
being a conscious decision — it just falls out of never having been questioned. The cost of
making it configurable up front is trivial (one env var); the cost of discovering it's
missing is a full failed deploy cycle, discovered by a human clicking a button.

### Why this matters together, not separately

Neither gap alone was sufficient to cause the failure — either a correctly-verified infra
decision *or* a configurable frontend would have prevented it. They compounded because
**nobody's job, on either side, was to verify the seam between them.** The infra plan assumed
the frontend could point anywhere; the frontend assumed infra would keep it same-origin.
Both assumptions were reasonable in isolation and wrong together, and nothing in either
verification pass (backend router check; frontend "it builds and runs locally") was designed
to catch a topology mismatch.

## Contributing near-misses from the same deploy (smaller instances of the same pattern)

Every one of these also passed its own local verification while being wrong in a way that
verification didn't check:

| Issue | What was checked | What was actually wrong | Same pattern? |
|---|---|---|---|
| Node 18 via apt vs. frontend needing ≥20 | `apt-get install` succeeded | Frontend build failed downstream | Package "installed successfully" ≠ "the right version for what depends on it" |
| certbot's `-m REPLACE_WITH_ADMIN_EMAIL` never sed-replaced | Script had a domain-replace step | Only `nginx.conf`'s placeholder was covered, not the script's own inline one | Fixed one occurrence of a pattern, assumed it covered all occurrences |
| systemd `EnvironmentFile` inline comments | Service started, `/health` → 200 | `NEWSAGENT_EMAIL_SENDER` silently carried its comment as part of the value | Service "healthy" tested process liveness, not per-field config correctness |
| Invisible Unicode mark in pasted Postgres URL | Value was "set" (non-empty check) | psycopg's strict parser rejected it | Non-empty ≠ well-formed |
| Neon DB assumed fresh | Connection succeeded, `alembic upgrade head` exit 0 | DB already had Naomi's dev data — `upgrade head` was silently a no-op | "Command succeeded" was read as "state is what I expected" without checking |

## Recommendation: verification checklist for future cross-repo/cloud deploy work

**Before locking an architecture decision that spans a boundary (frontend↔backend, repo↔repo,
service↔service):**
- Read (or run) the actual interaction on *both* sides — not the structure of one side plus
  reasoning about the other.
- State explicitly, in the decision record, which side's actual code was read and which was
  inferred. "Confirmed by reading X" should list every file that was actually opened.

**Before treating a deploy as verified/complete:**
- A health check tests that the process is alive, not that its configuration is correct or
  that its dependents can reach it. For each user-facing flow (login, not just "the page
  loads"), do one real click/request through the actual path, not just an endpoint that's
  convenient to curl.
- "Command exited 0" is not "state matches what I expected" — for anything idempotent
  (migrations, seeding, `apt install`), check the actual resulting state, not just the exit
  code.

**For any hardcoded value that names an external location (API base URL, DB URL, service
host):** if it's ever going to run somewhere other than localhost, it needs to be
configurable before that first real deploy — not discovered missing during one.

**For copy-pasted secrets/connection strings:** validate them (e.g. scan for non-ASCII
characters, attempt a real connection) before trusting a "value is set" check.
