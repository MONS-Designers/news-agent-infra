#!/usr/bin/env bash
# Resolves which commit SHA a rollback should retag an environment's moving
# tag to (CAP-3, spec-gitops-deploy-trigger). Used by
# .github/workflows/rollback.yml. Requires `az acr login`-equivalent access
# already established (OIDC login done by the caller) -- this script only
# reads ACR metadata, it does not import/retag anything itself.
#
# Usage: resolve-rollback-sha.sh <repo> <moving-tag> [requested-sha]
#   repo         -- e.g. newsagent-api or newsagent-frontend
#   moving-tag   -- e.g. stage-latest or latest
#   requested-sha -- optional; when given, just validated and echoed back.
#                    When omitted, resolves "one step back": the SHA-tagged
#                    build immediately before whichever one currently backs
#                    the moving tag.
#
# Prints "sha=<value>" on success (consumable via $GITHUB_OUTPUT), exits
# non-zero with a message on stderr on any failure -- never retags nothing
# silently.
#
# Caveat on the no-sha ("one step back") path: it orders manifests by
# `time_desc` and takes the newest SHA-tagged one that isn't the moving tag's
# current digest. That assumes `time_desc` reflects each manifest's creation
# time, not its last-*retagged* time -- unverified against live ACR
# behavior. If it turns out to be the latter, a second consecutive rollback
# (with no explicit sha) could resolve to the wrong image, since the
# just-demoted digest may resurface out of order. For anything beyond a
# single hop back, pass an explicit sha instead of relying on this path
# twice in a row.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: resolve-rollback-sha.sh <repo> <moving-tag> [requested-sha]" >&2
  exit 2
fi

repo="$1"
moving_tag="$2"
requested_sha="${3:-}"
# Same registry rollback.yml's job-level ACR_NAME env var names -- read from
# there (inherited automatically since this script runs as a `run:` step in
# that job) rather than a second hardcoded literal that could drift from it.
acr_name="${ACR_NAME:-newsagentacr}"

if [ -n "$requested_sha" ]; then
  if ! az acr repository show --name "$acr_name" --image "$repo:$requested_sha" >/dev/null 2>&1; then
    echo "No image $repo:$requested_sha found in $acr_name -- was it ever built/pushed?" >&2
    exit 1
  fi
  echo "sha=$requested_sha"
  exit 0
fi

manifests="$(az acr manifest list-metadata --registry "$acr_name" --name "$repo" --orderby time_desc -o json)"

current_digest="$(echo "$manifests" | jq -r --arg tag "$moving_tag" '
  [.[] | select(.tags != null and (.tags | index($tag)))][0].digest // empty
')"

if [ -z "$current_digest" ]; then
  echo "Could not find a manifest currently tagged $repo:$moving_tag in $acr_name" >&2
  exit 1
fi

previous_sha="$(echo "$manifests" | jq -r --arg digest "$current_digest" '
  [.[] | select(.digest != $digest) | (.tags // [])[] | select(test("^[0-9a-f]{40}$"))][0] // empty
')"

if [ -z "$previous_sha" ]; then
  echo "No previous SHA-tagged build found for $repo in $acr_name -- nothing to roll back to" >&2
  exit 1
fi

echo "sha=$previous_sha"
