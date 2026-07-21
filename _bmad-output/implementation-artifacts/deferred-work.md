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
