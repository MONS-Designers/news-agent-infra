# Stage environment baseline for NewsAgent's Azure App Service GitOps migration.
# Smoke-test slice: proves a real containerized frontend + backend can run in
# Azure, now with real secrets via a shared Key Vault (renegotiated
# 2026-08-21 -- was deferred, see Spec Change Log in
# ../_bmad-output/implementation-artifacts/spec-stage-deploy-baseline.md).
# The automatic deploy trigger (also deferred here originally) is now live:
# DOCKER_ENABLE_CI + a moving ACR tag per environment, no Azure Function, no
# tag file -- see ../_bmad-output/specs/spec-gitops-deploy-trigger/.
#
# ACR and Key Vault live in newsagent-shared-rg -- reused by stage AND the
# not-yet-built prod slice, per the user's explicit design (2026-08-21).
# State is local (terraform.tfstate in this dir), by explicit user choice.

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}

# --- Shared resources: reused by stage AND (later) prod ---

resource "azurerm_resource_group" "shared" {
  name     = var.shared_resource_group_name
  location = var.location
}

resource "azurerm_container_registry" "shared" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_key_vault" "shared" {
  name                = var.key_vault_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # `enable_rbac_authorization` is deprecated in this provider version in
  # favor of `rbac_authorization_enabled` (confirmed via `terraform providers
  # schema`) -- using the current name to avoid a deprecation warning.
  rbac_authorization_enabled = true

  # Still a tear-down-able smoke-test slice, not prod -- revisit purge
  # protection when the prod slice lands.
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

# RBAC authorization (above) means creating the vault does NOT itself grant
# secret read/write -- that's a separate data-plane permission in Azure, even
# for the identity that just created the vault. Without this, `terraform
# apply` gets a 403 (ForbiddenByRbac) trying to write the secrets below.
# Confirmed by hitting exactly that error on the first apply attempt
# (2026-08-21), not a hypothetical.
resource "azurerm_role_assignment" "deployer_kv_access" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC role assignments are eventually consistent -- a short explicit
# wait avoids a second failed apply while the assignment above propagates.
resource "time_sleep" "wait_for_deployer_kv_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_kv_access]
  create_duration = "30s"
}

# Secret values default empty; set real ones via a gitignored
# terraform.tfvars (or TF_VAR_*), or post-apply with `az keyvault secret set`
# -- never hardcoded here.
resource "azurerm_key_vault_secret" "api_stage_database_url" {
  name         = "newsagent-api-stage-database-url"
  value        = var.database_url
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_stage_smtp_password" {
  name         = "newsagent-api-stage-smtp-password"
  value        = var.smtp_password
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_stage_google_client_secret" {
  name         = "newsagent-api-stage-google-client-secret"
  value        = var.google_client_secret
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_stage_session_secret" {
  name         = "newsagent-api-stage-session-secret"
  value        = var.session_secret
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

# Prod's own secrets, same shared vault, `-prod-` naming per the convention
# the `-stage-` names were deliberately chosen to leave room for.
resource "azurerm_key_vault_secret" "api_prod_database_url" {
  name         = "newsagent-api-prod-database-url"
  value        = var.database_url_prod
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_prod_smtp_password" {
  name         = "newsagent-api-prod-smtp-password"
  value        = var.smtp_password_prod
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_prod_google_client_secret" {
  name         = "newsagent-api-prod-google-client-secret"
  value        = var.google_client_secret_prod
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

resource "azurerm_key_vault_secret" "api_prod_session_secret" {
  name         = "newsagent-api-prod-session-secret"
  value        = var.session_secret_prod
  key_vault_id = azurerm_key_vault.shared.id
  depends_on   = [time_sleep.wait_for_deployer_kv_rbac]
}

# Credential A: news-agent-infra's own deploy.yml/rollback.yml GitHub Actions
# authenticate as this identity via OIDC (no stored Azure secret) to push
# images to the shared ACR and to retag them on rollback (az acr import --
# same AcrPush role covers both, see pipeline-design.md's Credentials
# section). Scoped to AcrPush only. Lives in the shared RG since it's not
# stage-specific -- one identity, one push target, regardless of how many
# environments consume images from it. Originally used by news-agent's own
# CI; re-pointed to this repo's main branch by spec-gitops-deploy-trigger
# once the pipeline moved here (see the federated-identity comment below).
resource "azurerm_user_assigned_identity" "ci_acr_push" {
  name                = "newsagent-ci-acr-push"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
}

# GitHub's OIDC subject now includes immutable owner/repo IDs, not just names
# (rolled out 2026-04-23, https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
# -- both news-agent and news-agent-infra are enrolled). A name-only subject
# here fails OIDC exchange with AADSTS700213 "No matching federated identity
# record found", even though client-id/tenant-id/subscription-id are all
# correct -- confirmed by hitting that exact error against the previous
# subject format.
#
# Re-pointed (spec-gitops-deploy-trigger) from news-agent's refs/heads/dev to
# news-agent-infra's own refs/heads/main -- the build/push/deploy pipeline
# (deploy.yml, rollback.yml) now runs here, not in news-agent, so this is the
# ref whose OIDC token actually needs to authenticate. `name` stays
# "news-agent-dev-push" (now a misnomer) rather than being renamed: renaming
# it forces Terraform to destroy+recreate the credential instead of updating
# it in place, for no functional benefit.
resource "azurerm_federated_identity_credential" "ci_acr_push_github" {
  name      = "news-agent-dev-push"
  parent_id = azurerm_user_assigned_identity.ci_acr_push.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo_name}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}"
}

resource "azurerm_role_assignment" "ci_acr_push" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.ci_acr_push.principal_id
}

# CAP-3 rollback (az acr import) is a management-plane operation -- AcrPush above only grants
# the data-plane pull/push actions and does NOT include importImage. Microsoft's own docs for
# same-registry import require this exact built-in role on the target registry.
resource "azurerm_role_assignment" "ci_acr_import" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "Container Registry Data Importer and Data Reader"
  principal_id         = azurerm_user_assigned_identity.ci_acr_push.principal_id
}

# --- Stage environment ---

resource "azurerm_resource_group" "stage" {
  name     = var.resource_group_name
  location = var.location
}

# One shared Linux plan for both stage apps.
resource "azurerm_service_plan" "stage" {
  name                = "newsagent-stage-plan"
  resource_group_name = azurerm_resource_group.stage.name
  location            = azurerm_resource_group.stage.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# Backend. Tracks the moving `stage-latest` tag in newsagentacr (previously
# a public placeholder image before spec-gitops-deploy-trigger -- no deploy
# pipeline populated a real image until then). WEBSITES_PORT is required:
# the backend Dockerfile binds uvicorn to 8000, not App Service's default of
# 80.
#
# DOCKER_ENABLE_CI=true (app_settings below) is what makes this auto-deploy:
# Azure auto-creates and owns an ACR webhook that fires whenever
# newsagent-api:stage-latest is repushed, pulling + restarting this app --
# no azurerm_container_registry_webhook resource, no explicit
# `az webapp config container set` step anywhere in the pipeline (see
# pipeline-design.md's Credentials section). Bootstrap ordering matters: the
# stage-latest tag must exist in ACR (i.e. deploy.yml must have run at least
# once) before this config is applied, or the app has nothing to pull --
# see deploy/for-naomi/README.md's manual-steps section.
#
# System-assigned identity + Key Vault references in app_settings: Azure
# resolves the @Microsoft.KeyVault(...) strings at runtime using this
# identity, and retries automatically if the role assignment hasn't
# propagated yet -- no explicit depends_on needed for correctness (and one
# from this resource onto the role assignment below would be a cycle, since
# the role assignment needs this resource's identity to exist first).
# Non-secret settings the API needs to actually run are wired directly (every
# NEWSAGENT_* field has a Python-level default, so the app boots without
# these too, but a meaningful smoke test needs them set).
resource "azurerm_linux_web_app" "api_stage" {
  name                = "newsagent-api-stage"
  resource_group_name = azurerm_resource_group.stage.name
  location            = azurerm_resource_group.stage.location
  service_plan_id     = azurerm_service_plan.stage.id

  site_config {
    # Required to pull from newsagentacr -- the registry's admin user is
    # deliberately disabled, so there's no username/password to fall back
    # on; this app's own identity (below) is the only auth path, via the
    # AcrPull role assignment below.
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = "newsagent-api:stage-latest"
      docker_registry_url = "https://${azurerm_container_registry.shared.login_server}"
    }
  }

  # Pre-existing live config, not captured here before -- codified rather than
  # letting `terraform apply` silently drop it. HTTP access logs (3 days /
  # 100MB) are the useful part; the two detail toggles are already off.
  logs {
    detailed_error_messages = false
    failed_request_tracing  = false

    http_logs {
      file_system {
        retention_in_days = 3
        retention_in_mb   = 100
      }
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT    = "8000"
    DOCKER_ENABLE_CI = "true"

    # Stateless container -- nothing written to /home needs to survive a
    # restart. Pre-existing live config, codified here rather than left as
    # drift for `terraform apply` to silently reset.
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"

    NEWSAGENT_DATABASE_URL         = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_stage_database_url.versionless_id})"
    NEWSAGENT_SMTP_PASSWORD        = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_stage_smtp_password.versionless_id})"
    NEWSAGENT_GOOGLE_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_stage_google_client_secret.versionless_id})"
    NEWSAGENT_SESSION_SECRET       = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_stage_session_secret.versionless_id})"

    # Same predictable <name>.azurewebsites.net pattern as the "name" argument
    # above -- can't reference this resource's own default_hostname from
    # inside itself (that's a self-reference cycle).
    NEWSAGENT_BACKEND_BASE_URL = "https://newsagent-api-stage.azurewebsites.net"
    NEWSAGENT_FRONTEND_URL     = "https://${azurerm_linux_web_app.frontend_stage.default_hostname}"

    NEWSAGENT_GOOGLE_CLIENT_ID  = var.google_client_id
    NEWSAGENT_SMTP_USERNAME     = var.smtp_username
    NEWSAGENT_SMTP_HOST         = "smtp.gmail.com"
    NEWSAGENT_SMTP_PORT         = "587"
    NEWSAGENT_SMTP_FROM_ADDRESS = "newsagent.ai.01@gmail.com"

    # Deliberate safety default -- stage can't accidentally send real email
    # before real SMTP creds are ever set.
    NEWSAGENT_EMAIL_SENDER = "console"
  }
}

resource "azurerm_role_assignment" "api_stage_kv_access" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.api_stage.identity[0].principal_id
}

resource "azurerm_role_assignment" "api_stage_acr_pull" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.api_stage.identity[0].principal_id
}

# Frontend. Tracks the moving `stage-latest` tag in newsagentacr, same
# DOCKER_ENABLE_CI auto-deploy mechanism as api_stage above. WEBSITES_PORT=
# 8080 matches the real image (nginx-unprivileged, see
# deploy/for-naomi/Dockerfile.frontend). No Key Vault access -- static SPA,
# nothing to fetch there -- but it does need an identity to pull its own
# image from the (admin-disabled) ACR.
resource "azurerm_linux_web_app" "frontend_stage" {
  name                = "newsagent-frontend-stage"
  resource_group_name = azurerm_resource_group.stage.name
  location            = azurerm_resource_group.stage.location
  service_plan_id     = azurerm_service_plan.stage.id

  site_config {
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = "newsagent-frontend:stage-latest"
      docker_registry_url = "https://${azurerm_container_registry.shared.login_server}"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT    = "8080"
    DOCKER_ENABLE_CI = "true"

    # Stateless static-file server -- nothing written to /home needs to
    # survive a restart. Pre-existing live config, codified here rather than
    # left as drift for `terraform apply` to silently reset.
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"

    # Literal, not a reference to azurerm_linux_web_app.api_stage -- that
    # would create a cycle (api_stage's app_settings already reference this
    # resource for NEWSAGENT_FRONTEND_URL). Same predictable
    # <name>.azurewebsites.net pattern used there. nginx's envsubst template
    # (deploy/for-naomi/nginx.frontend.conf.template) reads this at
    # container start to reverse-proxy /api/* to the backend -- the same
    # image is promotable stage -> prod because this is set per-environment
    # here, not baked into the image.
    BACKEND_HOST = "newsagent-api-stage.azurewebsites.net"
  }
}

resource "azurerm_role_assignment" "frontend_stage_acr_pull" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.frontend_stage.identity[0].principal_id
}

# --- Prod environment: exact mirror of stage (user's explicit instruction,
# 2026-08-21) -- same shape, same shared ACR/Key Vault, own resource group,
# own App Service Plan, own secrets. Tracks the moving `latest` tag, fed by
# news-agent's own `main` branch (spec-gitops-deploy-trigger) -- fully
# decoupled from stage/`dev`, same DOCKER_ENABLE_CI auto-deploy mechanism. ---

resource "azurerm_resource_group" "prod" {
  name     = var.resource_group_name_prod
  location = var.location
}

resource "azurerm_service_plan" "prod" {
  name                = "newsagent-prod-plan"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "api_prod" {
  name                = "newsagent-api-prod"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  service_plan_id     = azurerm_service_plan.prod.id

  site_config {
    # See the matching comment on api_stage -- same admin-disabled-ACR
    # reasoning.
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = "newsagent-api:latest"
      docker_registry_url = "https://${azurerm_container_registry.shared.login_server}"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT    = "8000"
    DOCKER_ENABLE_CI = "true"

    NEWSAGENT_DATABASE_URL         = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_prod_database_url.versionless_id})"
    NEWSAGENT_SMTP_PASSWORD        = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_prod_smtp_password.versionless_id})"
    NEWSAGENT_GOOGLE_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_prod_google_client_secret.versionless_id})"
    NEWSAGENT_SESSION_SECRET       = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.api_prod_session_secret.versionless_id})"

    NEWSAGENT_BACKEND_BASE_URL = "https://newsagent-api-prod.azurewebsites.net"
    NEWSAGENT_FRONTEND_URL     = "https://${azurerm_linux_web_app.frontend_prod.default_hostname}"

    NEWSAGENT_GOOGLE_CLIENT_ID  = var.google_client_id_prod
    NEWSAGENT_SMTP_USERNAME     = var.smtp_username_prod
    NEWSAGENT_SMTP_HOST         = "smtp.gmail.com"
    NEWSAGENT_SMTP_PORT         = "587"
    NEWSAGENT_SMTP_FROM_ADDRESS = "newsagent.ai.01@gmail.com"

    # Same deliberate safety default as stage -- exact copy per the user's
    # instruction. Switch to "smtp" only when a real go-live is intended.
    NEWSAGENT_EMAIL_SENDER = "console"
  }
}

resource "azurerm_role_assignment" "api_prod_kv_access" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.api_prod.identity[0].principal_id
}

resource "azurerm_role_assignment" "api_prod_acr_pull" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.api_prod.identity[0].principal_id
}

resource "azurerm_linux_web_app" "frontend_prod" {
  name                = "newsagent-frontend-prod"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  service_plan_id     = azurerm_service_plan.prod.id

  site_config {
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = "newsagent-frontend:latest"
      docker_registry_url = "https://${azurerm_container_registry.shared.login_server}"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT    = "8080"
    DOCKER_ENABLE_CI = "true"

    # See the matching comment on frontend_stage -- same cycle-avoidance
    # reasoning, prod's own backend hostname.
    BACKEND_HOST = "newsagent-api-prod.azurewebsites.net"
  }
}

resource "azurerm_role_assignment" "frontend_prod_acr_pull" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.frontend_prod.identity[0].principal_id
}

output "shared_resource_group_name" {
  value = azurerm_resource_group.shared.name
}

output "resource_group_name" {
  value = azurerm_resource_group.stage.name
}

output "acr_login_server" {
  value = azurerm_container_registry.shared.login_server
}

output "key_vault_name" {
  value = azurerm_key_vault.shared.name
}

output "ci_identity_client_id" {
  description = "AZURE_CLIENT_ID for news-agent-infra's deploy.yml/rollback.yml OIDC login step (spec-gitops-deploy-trigger moved this here from news-agent)"
  value       = azurerm_user_assigned_identity.ci_acr_push.client_id
}

output "tenant_id" {
  description = "AZURE_TENANT_ID for news-agent-infra's deploy.yml/rollback.yml OIDC login step"
  value       = azurerm_user_assigned_identity.ci_acr_push.tenant_id
}

output "subscription_id" {
  description = "AZURE_SUBSCRIPTION_ID for news-agent-infra's deploy.yml/rollback.yml OIDC login step"
  value       = var.subscription_id
}

output "api_stage_default_hostname" {
  value = azurerm_linux_web_app.api_stage.default_hostname
}

output "frontend_stage_default_hostname" {
  value = azurerm_linux_web_app.frontend_stage.default_hostname
}

output "resource_group_name_prod" {
  value = azurerm_resource_group.prod.name
}

output "api_prod_default_hostname" {
  value = azurerm_linux_web_app.api_prod.default_hostname
}

output "frontend_prod_default_hostname" {
  value = azurerm_linux_web_app.frontend_prod.default_hostname
}
