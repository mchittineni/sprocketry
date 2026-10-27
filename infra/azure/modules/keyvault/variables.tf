variable "name" {
  description = "Key Vault name (globally unique, 3-24 chars)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "secrets" {
  description = "Secrets to store, keyed by Key Vault secret name."
  type        = map(string)
  sensitive   = true
}

variable "secrets_officer_principal_ids" {
  description = "Entra object IDs that can read and write secrets (whoever runs Terraform)."
  type        = set(string)
}

variable "purge_protection_enabled" {
  description = "Enable for prod. Off in dev so the vault can be destroyed and recreated."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
