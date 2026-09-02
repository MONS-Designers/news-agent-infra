# `/health` diff for `src/newsagent/api/main.py`

CAP-5 (`spec-gitops-deploy-trigger`): `deploy.yml` and `rollback.yml` in `news-agent-infra` need
`/health` to report which commit is actually running, since both environments track a fixed,
reused ACR tag rather than a tag that changes per push -- a green build/retag alone doesn't
prove the right code landed.

This is a snippet, not a whole-file handoff like the Dockerfiles -- `main.py` is your file, this
touches only the `/health` handler. Confirmed against the real current `dev`-branch content
(read via `gh api`, not guessed) before writing this.

## Add near the top, with the other imports

```python
import os
```

## Change the `/health` handler

Current:

```python
    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}
```

New:

```python
    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "commit": os.environ.get("GIT_SHA", "unknown")}
```

`GIT_SHA` comes from the `Dockerfile.backend` change in this same handoff (`ARG GIT_SHA=unknown`
baked in as `ENV GIT_SHA` at build time) -- nothing else needs to change. Reading it directly via
`os.environ` rather than threading a new field through `newsagent.config.settings` is a
deliberate call to keep this a one-line diff; happy to route it through `settings` instead if you
(Naomi) prefer that for consistency with the rest of the config surface.

`/health/db` is untouched -- this only adds a `commit` field to the plain `/health` check.
