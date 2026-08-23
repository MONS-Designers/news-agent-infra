# Stage environment baseline for NewsAgent's Azure App Service GitOps migration.
# Smoke-test slice: proves a real containerized frontend + backend can run in
# Azure, now with real secrets via a shared Key Vault (renegotiated
# 2026-08-21 -- was deferred, see Spec Change Log in
# ../_bmad-output/implementation-artifacts/spec-stage-deploy-baseline.md).
# No Function, no tag file, no prod environment yet -- deferred (see
# ../_bmad-output/implementation-artifacts/deferred-work.md).
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

# Credential A: news-agent's GitHub Actions authenticates as this identity via
# OIDC (no stored Azure secret) to push images to the shared ACR. Scoped to
# AcrPush only. Lives in the shared RG since it's not stage-specific -- one
# CI workflow, one push target, regardless of how many environments consume
# images from it.
resource "azurerm_user_assigned_identity" "ci_acr_push" {
  name                = "newsagent-ci-acr-push"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
}

# GitHub's OIDC subject now includes immutable owner/repo IDs, not just names
# (rolled out 2026-04-23, https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
# -- MONS-Designers/news-agent is enrolled). A name-only subject here fails
# OIDC exchange with AADSTS700213 "No matching federated identity record
# found", even though client-id/tenant-id/subscription-id are all correct --
# confirmed by hitting that exact error against the previous subject format.
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

# Backend. Starts on a public placeholder image -- no real image exists in
# ACR yet. WEBSITES_PORT is required once the real image ships: the backend
# Dockerfile binds uvicorn to 8000, not App Service's default of 80.
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
    # Required to pull from newsagentacr once a real (non-placeholder) image
    # tag is set -- the registry's admin user is deliberately disabled, so
    # there's no username/password to fall back on; this app's own identity
    # (below) is the only auth path, via the AcrPull role assignment below.
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = trimprefix(var.placeholder_image, "${trimprefix(var.placeholder_registry_url, "https://")}/")
      docker_registry_url = var.placeholder_registry_url
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT = "8000"

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

# Frontend. WEBSITES_PORT=8080 matches the real image (nginx-unprivileged,
# see deploy/for-naomi/Dockerfile.frontend) -- the placeholder may not answer
# on 8080 until the real image is set, which is expected for this slice. No
# Key Vault access -- static SPA, nothing to fetch there -- but it does need
# an identity to pull its own image from the (admin-disabled) ACR.
resource "azurerm_linux_web_app" "frontend_stage" {
  name                = "newsagent-frontend-stage"
  resource_group_name = azurerm_resource_group.stage.name
  location            = azurerm_resource_group.stage.location
  service_plan_id     = azurerm_service_plan.stage.id

  site_config {
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = trimprefix(var.placeholder_image, "${trimprefix(var.placeholder_registry_url, "https://")}/")
      docker_registry_url = var.placeholder_registry_url
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT = "8080"

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
# own App Service Plan, own secrets. Still on the placeholder image (no prod
# image pipeline/promotion exists yet -- CI only builds on push to `dev`,
# same as stage) and still no Function/tag-file deploy automation -- both
# remain deferred, see deferred-work.md. ---

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
      docker_image_name   = trimprefix(var.placeholder_image, "${trimprefix(var.placeholder_registry_url, "https://")}/")
      docker_registry_url = var.placeholder_registry_url
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT = "8000"

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
      docker_image_name   = trimprefix(var.placeholder_image, "${trimprefix(var.placeholder_registry_url, "https://")}/")
      docker_registry_url = var.placeholder_registry_url
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_PORT = "8080"

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
  description = "AZURE_CLIENT_ID for news-agent's OIDC login step"
  value       = azurerm_user_assigned_identity.ci_acr_push.client_id
}

output "tenant_id" {
  description = "AZURE_TENANT_ID for news-agent's OIDC login step"
  value       = azurerm_user_assigned_identity.ci_acr_push.tenant_id
}

output "subscription_id" {
  description = "AZURE_SUBSCRIPTION_ID for news-agent's OIDC login step"
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
