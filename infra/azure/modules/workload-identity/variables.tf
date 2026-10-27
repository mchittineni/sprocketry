variable "name_prefix" {
  description = "Prefix for identity names."
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

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL."
  type        = string
}

variable "identities" {
  description = "Identity name to the namespace and service accounts allowed to use it."
  type = map(object({
    namespace        = string
    service_accounts = list(string)
  }))
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
