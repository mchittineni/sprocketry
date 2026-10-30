variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "project" {
  description = "Short project name used in resource names."
  type        = string
  default     = "sprocketry"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "node_vm_size" {
  description = "VM size for AKS nodes."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_max_count" {
  description = "Maximum AKS nodes."
  type        = number
  default     = 3
}

variable "aks_api_authorized_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the AKS API from the internet: your IP and the egress range of anything that
    runs kubectl. Requests still need an Entra identity with cluster access.
  EOT
  type        = list(string)
}

variable "deployer_principal_ids" {
  description = <<-EOT
    Entra object IDs of everyone who runs Terraform for this environment: people, groups and the CI
    service principal. They get Key Vault secret write access and AKS cluster admin. Left empty, it
    falls back to whoever runs Terraform, which only suits one person with no CI plan.
  EOT
  type        = list(string)
  default     = []
}
