# Handoff: containerized deploy for news-agent (stage smoke test)

These files aren't applied anywhere yet — they're for Moshe to copy into
`news-agent` by hand (or open as a PR there) once the stage Terraform has
been applied. Nothing in `news-agent-infra`'s automation touches
`news-agent`'s repo directly.

## Where each file goes, inside `news-agent`

| This file | Goes to |
|---|---|
| `Dockerfile.backend` | repo root |
| `Dockerfile.frontend` | repo root |
| `nginx.frontend.conf` | repo root (same dir as `Dockerfile.frontend` — it's `COPY`'d in by path) |
| `docker-build-push.yml` | `.github/workflows/docker-build-push.yml` |

## One-time setup before the workflow can run

1. Run `terraform -chdir=../../terraform apply` (after reviewing the plan) in
   `news-agent-infra`, then `terraform -chdir=../../terraform output`.
2. In `news-agent`'s GitHub repo settings → Secrets and variables → Actions,
   add three repository secrets using the Terraform output values:
   - `AZURE_CLIENT_ID` ← `ci_identity_client_id`
   - `AZURE_TENANT_ID` ← `tenant_id`
   - `AZURE_SUBSCRIPTION_ID` ← `subscription_id`

   These aren't long-lived credentials — they just identify which managed
   identity to request an OIDC token as; the trust relationship itself lives
   in Azure (the federated identity credential), not in GitHub.
3. If the ACR name ever changes from `newsagentacr`, update the
   `ACR_LOGIN_SERVER` env var in `docker-build-push.yml` and the `az acr
   login --name` step to match.

## Setting real Key Vault secret values

`newsagent-api-stage` reads 4 secrets from a shared Key Vault (`newsagent-kv`,
in `newsagent-shared-rg` — shared with the not-yet-built prod environment)
via Key Vault references, resolved automatically at runtime — no code
changes needed in `news-agent`. They default to empty strings until set for
real, either way works:

```bash
# Post-apply, via the CLI (fastest, no state file changes)
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-database-url --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-smtp-password --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-google-client-secret --value "<real value>"
az keyvault secret set --vault-name newsagent-kv \
  --name newsagent-api-stage-session-secret --value "<real value>"
```

Or equivalently, put the same 4 values in a gitignored `terraform.tfvars` in
`news-agent-infra/terraform/` (`database_url`, `smtp_password`,
`google_client_secret`, `session_secret`) and re-run `terraform apply` — both
paths land in the same secret, pick whichever is convenient at the time. App
Service picks up a changed secret value without needing anything else
touched.

## First real deploy (manual — the automated pull mechanism is a later slice)

Once a push to `dev` has run the workflow and both images exist in ACR:

```bash
# Confirm the images landed
az acr repository show-tags --name newsagentacr --repository newsagent-api
az acr repository show-tags --name newsagentacr --repository newsagent-frontend

# Point each stage App Service at the real image (replace <sha> with the
# commit SHA the workflow built)
az webapp config container set \
  --name newsagent-api-stage \
  --resource-group newsagent-stage-rg \
  --container-image-name newsagentacr.azurecr.io/newsagent-api:<sha> \
  --container-registry-url https://newsagentacr.azurecr.io

az webapp config container set \
  --name newsagent-frontend-stage \
  --resource-group newsagent-stage-rg \
  --container-image-name newsagentacr.azurecr.io/newsagent-frontend:<sha> \
  --container-registry-url https://newsagentacr.azurecr.io
```

Then hit each app's default hostname (from the Terraform outputs
`api_stage_default_hostname` / `frontend_stage_default_hostname`) to confirm
the real app is running, not the placeholder.

## Not included here (deferred, see `deferred-work.md`)

- Anything that automatically applies a new image tag — that's the Azure
  Function slice, not built yet. This handoff only gets you to "the real app
  runs in Azure, verified once by hand."
- A production environment or cutover from the existing VM (though the ACR and
  Key Vault built here are already shared-ready for when it lands).
- Per-environment Key Vault access isolation — the stage app's identity has
  vault-level `Key Vault Secrets User` today, which will need tightening once
  real prod secrets share this same vault (logged in `deferred-work.md`).
