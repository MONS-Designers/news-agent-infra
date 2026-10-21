#!/usr/bin/env python3
"""Post-deploy smoke test against the live NewsAgent deployment.

Exists because a green `/health` check and a running systemd service both
passed while OAuth login was completely broken (2026-08-16 retro:
implementation-artifacts/retro-mvp-deploy-2026-08-16.md) — the frontend's
login link resolved against the wrong origin and nginx's SPA fallback
returned a 200 for it, so nothing here showed up as an error. This checks
the one thing that mattered: does the login link actually reach Google,
not just "does something respond with 200".

Usage: python deploy/smoke_test.py [--app-url URL] [--api-url URL]
Exit 0 = all checks passed. Exit 1 = at least one failed (details on stderr).
"""

import argparse
import sys
import urllib.error
import urllib.request
from urllib.request import HTTPRedirectHandler


# Cloudflare (in front of the custom domain) answers 403 to Python's default
# User-Agent, so every request carries a browser-style one.
USER_AGENT = "Mozilla/5.0 (compatible; newsagent-smoke-test)"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _opener():
    return urllib.request.build_opener(NoRedirect)


def _request(url: str) -> urllib.request.Request:
    return urllib.request.Request(url, headers={"User-Agent": USER_AGENT})


def check_200(name: str, url: str) -> list[str]:
    """Fails unless the URL returns exactly 200."""
    try:
        with urllib.request.urlopen(_request(url), timeout=10) as resp:
            if resp.status != 200:
                return [f"{name}: expected 200, got {resp.status} ({url})"]
            return []
    except urllib.error.URLError as e:
        return [f"{name}: request failed — {e} ({url})"]


def check_redirects_to_google(name: str, url: str) -> list[str]:
    """Fails if the URL doesn't redirect to Google — this is the exact
    shape of the 2026-08-16 bug: a same-origin SPA fallback returns 200
    with the wrong content instead of erroring, so a plain 200 check
    would have passed right through it."""
    try:
        with _opener().open(_request(url), timeout=10) as resp:
            return [
                f"{name}: expected a redirect (3xx), got {resp.status} "
                f"with no Location header — likely hitting a static-file "
                f"fallback instead of the backend ({url})"
            ]
    except urllib.error.HTTPError as e:
        if e.status not in (301, 302, 303, 307, 308):
            return [f"{name}: expected a redirect (3xx), got {e.status} ({url})"]
        location = e.headers.get("Location", "")
        if "accounts.google.com" not in location:
            return [
                f"{name}: redirected, but not to Google — got Location: "
                f"{location!r} ({url})"
            ]
        return []
    except urllib.error.URLError as e:
        return [f"{name}: request failed — {e} ({url})"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-url", default="https://newsagent-ai.com")
    parser.add_argument("--api-url", default="https://newsagent-api-prod.azurewebsites.net")
    args = parser.parse_args()

    failures: list[str] = []
    failures += check_200("frontend loads", args.app_url + "/")
    failures += check_200("backend health", args.api_url + "/health")
    failures += check_redirects_to_google(
        "login via frontend origin", args.app_url + "/api/auth/login"
    )
    failures += check_redirects_to_google(
        "login via backend directly", args.api_url + "/auth/login"
    )

    if failures:
        print("SMOKE TEST FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("Smoke test passed: frontend, backend health, and login redirect all OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
