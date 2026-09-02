#!/usr/bin/env bash
# Polls a URL serving JSON with a "commit" field every 5s for up to 180s,
# failing loudly if it never matches the expected SHA. Used by
# .github/workflows/deploy.yml and rollback.yml to verify a deploy actually
# landed (CAP-5, spec-gitops-deploy-trigger) -- App Service tracks a fixed
# moving tag rather than a tag that changes per push, so a green build/retag
# step alone doesn't prove the right code is running.
#
# jq -e is deliberate: a missing/unreachable file (e.g. a request for
# version.json before nginx has it) can come back as nginx's SPA fallback
# (index.html, HTTP 200) rather than a 404 -- a raw curl -f success would
# wrongly treat that as reachable. jq -e fails on non-JSON or a missing
# .commit field, so that case is correctly treated as "not yet matching" and
# retried, not accepted as success.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: verify-commit.sh <url> <expected-sha>" >&2
  exit 2
fi

url="$1"
expected_sha="$2"

# Fail fast rather than polling for the full 180s against a target that can
# never match -- e.g. deploy.yml was fired with a missing/malformed sha
# (a repository_dispatch call outside trigger-deploy.yml, bypassing its
# payload shape).
if [ -z "$expected_sha" ]; then
  echo "FAILED: expected-sha is empty -- nothing to verify against" >&2
  exit 1
fi

interval=5
timeout=180
elapsed=0
actual_sha=""

echo "Polling $url for commit=$expected_sha (every ${interval}s, timeout ${timeout}s)..."
while [ "$elapsed" -lt "$timeout" ]; do
  # --max-time bounds a single hung/slow-dropping connection -- without it,
  # elapsed only accounts for the sleep between attempts, so one stalled
  # curl call could blow well past the intended 180s wall-clock cap.
  actual_sha="$(curl -fsS --max-time 10 "$url" 2>/dev/null | jq -er '.commit' 2>/dev/null || true)"
  if [ "$actual_sha" = "$expected_sha" ]; then
    echo "OK: $url reports commit $actual_sha"
    exit 0
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

echo "FAILED: $url did not report commit $expected_sha within ${timeout}s (last seen: '${actual_sha:-<none>}')" >&2
exit 1
