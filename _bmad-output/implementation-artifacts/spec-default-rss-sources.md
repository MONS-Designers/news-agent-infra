---
title: 'Default RSS source list for NewsAgent'
type: 'feature'
created: '2026-07-20'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: 'NO_VCS'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** news-agent-infra owns the default/starter list of RSS sources for the Hebrew
digest agent, but no such list exists yet — the admin has nothing to review/approve in
news-agent's source-approval UI, and no data format has been established for it.

**Approach:** Add a YAML data file of curated, real, working RSS feeds (name, feed URL,
category, source language) covering a few starter topic categories, plus a small standalone
Python script that validates the file is well-formed (required fields present, URLs
syntactically valid, categories from a known set, no duplicate name/url).

## Boundaries & Constraints

**Always:**
- Every source entry has `name`, `url`, `category`, `language` — all non-empty strings.
- `url` uses `http`/`https` scheme and has a network location (basic syntactic check only).
- `category` is one of the file's declared starter categories (`tech`, `world_news`, `science`).
- Only real, currently-live RSS/Atom feeds from reputable outlets — verified reachable
  (HTTP 200 + feed-like root XML tag) before being added.
- No duplicate `name` or `url` across entries.

**Ask First:** Adding a language other than English to the starter set (none needed for this
pass — all chosen feeds are English, translated to Hebrew downstream per product scope).

**Never:**
- No wiring into news-agent's ingestion pipeline, admin UI, or database — that is a future,
  separate task once the two repos agree on an interface.
- No fetching/parsing of actual feed article content, no scheduler, no email delivery.
- No new Python package/project scaffolding beyond what the validator needs (no src/ layout,
  no build config) — this repo has no such scaffolding yet and none is requested.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path | Well-formed `default_sources.yaml` | Validator prints `OK: N sources validated`, exit 0 | N/A |
| Missing field | Entry missing `category` | Validator reports which entry/field, exit 1 | Message names entry `name` (or index) + missing field |
| Malformed URL | `url: "not-a-url"` | Validator reports invalid URL for that entry, exit 1 | Message names entry + offending value |
| Unknown category | `category: "sports"` | Validator reports category not in declared set, exit 1 | Message lists allowed categories |
| Duplicate entry | Two entries share `url` | Validator reports the duplicate, exit 1 | Message names both entries/index |

</frozen-after-approval>

## Code Map

- `sources/default_sources.yaml` -- new: the default source list (data only)
- `sources/validate_sources.py` -- new: standalone validation script (stdlib + PyYAML)
- `sources/test_validate_sources.py` -- new: pytest coverage for the I/O matrix above
- `requirements.txt` -- new: `pyyaml`, `pytest` (first Python tooling in this repo)

## Tasks & Acceptance

**Execution:**
- [x] `requirements.txt` -- add `pyyaml` and `pytest` -- validator and its tests need a YAML parser and a test runner; nothing else in this repo pins dependencies yet
- [x] `sources/default_sources.yaml` -- author `sources:` list of ~10 real, verified-live feeds: `tech` (4 -- The Verge, Wired, Ars Technica, Hacker News), `world_news` (3), `science` (3), each with `name`, `url`, `category`, `language: en` -- gives the admin a genuinely useful, reviewable starting point
- [x] `sources/validate_sources.py` -- load the YAML, check each entry against Always-rules above, print a clear per-entry error and exit 1 on first class of failure found (collect all errors, don't stop at first), exit 0 with a summary count on success -- turns "well-formed" from a task description into an enforced, repeatable check
- [x] `sources/test_validate_sources.py` -- pytest cases for: happy path, missing field, malformed URL, unknown category, duplicate url/name -- proves the validator actually catches the edge cases it claims to

**Acceptance Criteria:**
- Given `sources/default_sources.yaml` as committed, when `python3 sources/validate_sources.py sources/default_sources.yaml` runs, then it exits 0 and reports the entry count.
- Given a copy of the file with one entry missing `language`, when the validator runs against it, then it exits non-zero and names the offending entry.
- Given `pytest sources/test_validate_sources.py`, when run, then all cases pass.

## Design Notes

Schema is intentionally minimal (`name`, `url`, `category`, `language`) — exactly the fields
the task scope calls for. No `id`, `enabled`, or scoring/status fields: those belong to the
future admin-approval/scoring interface this task explicitly excludes, and inventing them now
would guess at a cross-repo contract neither repo has agreed on yet.

Example entry:
```yaml
sources:
  - name: "BBC News - World"
    url: "http://feeds.bbci.co.uk/news/world/rss.xml"
    category: world_news
    language: en
```

## Verification

**Commands:**
- `pip install -r requirements.txt` -- expected: installs cleanly
- `python3 sources/validate_sources.py sources/default_sources.yaml` -- expected: exit 0, `OK: 10 sources validated`
- `pytest sources/test_validate_sources.py -q` -- expected: all tests pass

## Suggested Review Order

**Validation logic**

- Core function enforcing every Always-rule: required fields, url syntax, category, duplicates.
  [`validate_sources.py:21`](../../sources/validate_sources.py#L21)

- Review patch: rejects a technically-parseable but empty `sources:` list.
  [`validate_sources.py:28`](../../sources/validate_sources.py#L28)

- Review patch: category compared after stripping, matching the presence check's own whitespace handling.
  [`validate_sources.py:53`](../../sources/validate_sources.py#L53)

- Review patch: duplicate name/url detection normalized to stripped keys, closing a whitespace bypass found in review.
  [`validate_sources.py:58`](../../sources/validate_sources.py#L58)

- CLI now also catches `UnicodeDecodeError` so a malformed-encoding file fails cleanly instead of a raw traceback.
  [`validate_sources.py:89`](../../sources/validate_sources.py#L89)

**Default source data**

- 10 real, live-verified feeds across tech/world_news/science; fields match `REQUIRED_FIELDS` above.
  [`default_sources.yaml:1`](../../sources/default_sources.yaml#L1)

**Tests**

- Review patch: multi-error accumulation was the validator's stated design goal but had no test until now.
  [`test_validate_sources.py:164`](../../sources/test_validate_sources.py#L164)

- Review patch: CLI/subprocess-level coverage — exit codes were previously only implied by the spec's ACs, not tested.
  [`test_validate_sources.py:185`](../../sources/test_validate_sources.py#L185)

- Review patch: regression tests for the whitespace and empty-list bugs found above.
  [`test_validate_sources.py:125`](../../sources/test_validate_sources.py#L125)

- Original edge-case coverage from the I/O matrix: missing field, malformed url, unknown category, duplicates.
  [`test_validate_sources.py:43`](../../sources/test_validate_sources.py#L43)

**Peripherals**

- New dependency pins for this repo's first Python tooling.
  [`requirements.txt:1`](../../requirements.txt#L1)

- Ignores Python build artifacts (`__pycache__/`, `.pytest_cache/`) generated while running the verification commands above.
  [`.gitignore:6`](../../.gitignore#L6)

