# news-agent-infra — repo instructions

DevOps side of NewsAgent: server, daily scheduler, email delivery, default source list,
secrets, LLM cost control. See `../CLAUDE.md` (parent dir) for the shared product context —
this file only covers what's specific to working *in this repo*.

## Forbidden

- Never edit files in, or run commands against, the sibling repo `news-agent` (Naomi's)
  without flagging it to the user first, every time. The repos are owned by different people.
- Never commit secrets (`.env*`, credentials, kubeconfig, API keys, tokens).

## Conventions

- Source list entries (`sources/default_sources.yaml`) require `name`, `url`, `category`,
  `language`. `category` must be one of `tech`, `world_news`, `science` — see
  `REQUIRED_FIELDS` / `ALLOWED_CATEGORIES` in `sources/validate_sources.py`. Run that script
  after editing the YAML; it also rejects duplicate names/urls and malformed URLs.
- Stick to stdlib + `pyyaml` + `pytest` (see `requirements.txt`) — don't add a new dependency
  without updating `requirements.txt` and a good reason.
- Tests live next to the module they cover (e.g. `sources/test_validate_sources.py`), run via
  `pytest`.
- Never hardcode a count, size, or other fact derived from code or tests without checking it
  against the current source first — see `.claude/rules/no-stale-counts.md` for the full rule
  and a real example of this going wrong.

## Stack & Commands

- Python, stdlib-heavy, no framework.
- `python sources/validate_sources.py` — validate the default source list.
- `pytest sources/` — run tests.
- `python deploy/smoke_test.py` — post-deploy smoke test against the live URLs.

## Cross-repo integration

Before locking any architecture decision that spans the frontend/backend boundary, or that
depends on how `news-agent` actually behaves: trace the real interaction end-to-end — read or
run the actual code path on **both** sides — rather than reading one side's structure and
inferring the other. A subdomain-split deploy decision was once locked by checking only the
backend's router prefixes (`api/main.py`); the frontend's hardcoded relative API base URL
(`client.ts`) broke login as a result, invisibly, since nginx's SPA fallback returned 200 for
the broken path instead of an error. Full writeup:
`_bmad-output/implementation-artifacts/retro-mvp-deploy-2026-08-16.md`. When a decision touches
Naomi's side of the contract, a two-line message to her before locking it in is cheaper than
discovering the gap after a deploy.

## Deploy verification (definition of done)

A deploy is not "done" when systemd services show `active` and `/health` returns 200 — those
prove the process is alive, not that dependent flows (login, admin actions, digest send) work.
Before reporting a deploy complete:
- Run `python deploy/smoke_test.py` against the live URLs. It also runs on a schedule
  (`.github/workflows/smoke-test.yml`) as a standing regression check, but run it manually
  right after any deploy — don't wait for the next scheduled run.
- For any flow the smoke test can't check headlessly (anything needing real OAuth completion),
  exercise it once for real — a real click — rather than assuming a passing automated check
  covers it.

## Background

- A source scoring/quality mechanism (good vs. not) is planned for `sources/` but not yet
  designed. Don't add scoring logic on your own guess — check in first.
- `_bmad-output/` is the BMad-method planning trail (forged idea, market research) — historical
  context, not code; don't treat it as current spec.
- `.bmad-loop/` is orchestration state for the BMad loop skill — not something to hand-edit.
- Current MVP scope is authoritative in `news-agent/README.md`, per the parent CLAUDE.md.
