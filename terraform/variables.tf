variable "subscription_id" {
  description = "Azure subscription ID (Azure for Students, NewsAgent)"
  type        = string
  default     = "32c57b77-4b61-4359-850e-0baf5551d889"
}

variable "location" {
  description = "Azure region for the stage environment"
  type        = string
  default     = "israelcentral"
}

variable "resource_group_name" {
  description = "Dedicated resource group for stage App Services — never the existing newsagent-rg"
  type        = string
  default     = "newsagent-stage-rg"
}

variable "resource_group_name_prod" {
  description = "Dedicated resource group for prod App Services — separate from stage, shares ACR/Key Vault"
  type        = string
  default     = "newsagent-prod-rg"
}

variable "shared_resource_group_name" {
  description = "Resource group for resources reused across stage AND prod (ACR, Key Vault)"
  type        = string
  default     = "newsagent-shared-rg"
}

variable "acr_name" {
  description = "Azure Container Registry name (globally unique, alphanumeric only) — shared across environments"
  type        = string
  default     = "newsagentacr"
}

variable "key_vault_name" {
  description = "Key Vault name (globally unique) — shared across environments"
  type        = string
  default     = "newsagent-kv"
}

variable "github_org" {
  description = "GitHub org whose Actions workflow is trusted for OIDC push to ACR"
  type        = string
  default     = "MONS-Designers"
}

variable "github_org_id" {
  description = "GitHub's numeric ID for github_org -- required in the federated identity subject since MONS-Designers is enrolled in immutable OIDC subject claims. Look up via: gh api orgs/<org> --jq .id"
  type        = string
  default     = "174935491"
}

variable "github_repo_name" {
  description = "Repo name (without org prefix) whose Actions workflow is trusted for OIDC push to ACR -- news-agent-infra itself: the build/push/deploy pipeline (deploy.yml) runs here now, not in news-agent (spec-gitops-deploy-trigger)."
  type        = string
  default     = "news-agent-infra"
}

variable "github_repo_id" {
  description = "GitHub's numeric ID for github_repo_name -- same immutable-subject-claim requirement as github_org_id. Look up via: gh api repos/<org>/<repo> --jq .id"
  type        = string
  default     = "1302889366"
}

variable "github_branch" {
  description = "Branch whose push-triggered workflow is trusted for OIDC -- news-agent-infra's own main (deploy.yml and rollback.yml both live there), not news-agent's dev."
  type        = string
  default     = "main"
}

# --- Key Vault secret values ---
# Default empty on purpose. Real values go in a gitignored terraform.tfvars
# (or TF_VAR_*) at apply time, or are set post-apply with
# `az keyvault secret set` — never hardcoded here, never committed.

variable "database_url" {
  description = "Real value for the newsagent-api-stage-database-url Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_password" {
  description = "Real value for the newsagent-api-stage-smtp-password Key Vault secret (Gmail App Password)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "google_client_secret" {
  description = "Real value for the newsagent-api-stage-google-client-secret Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "session_secret" {
  description = "Real value for the newsagent-api-stage-session-secret Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Non-secret API app settings ---
# Not sensitive enough to warrant Key Vault, but no safe real value to
# hardcode either.

variable "google_client_id" {
  description = "NEWSAGENT_GOOGLE_CLIENT_ID app setting on newsagent-api-stage"
  type        = string
  default     = ""
}

variable "smtp_username" {
  description = "NEWSAGENT_SMTP_USERNAME app setting on newsagent-api-stage"
  type        = string
  default     = ""
}

# --- Prod: same 6 values, own variables (prod will hold different real
# values than stage, even though the shape is an exact copy) ---

variable "database_url_prod" {
  description = "Real value for the newsagent-api-prod-database-url Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_password_prod" {
  description = "Real value for the newsagent-api-prod-smtp-password Key Vault secret (Gmail App Password)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "google_client_secret_prod" {
  description = "Real value for the newsagent-api-prod-google-client-secret Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "session_secret_prod" {
  description = "Real value for the newsagent-api-prod-session-secret Key Vault secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "google_client_id_prod" {
  description = "NEWSAGENT_GOOGLE_CLIENT_ID app setting on newsagent-api-prod"
  type        = string
  default     = ""
}

variable "smtp_username_prod" {
  description = "NEWSAGENT_SMTP_USERNAME app setting on newsagent-api-prod"
  type        = string
  default     = ""
}
