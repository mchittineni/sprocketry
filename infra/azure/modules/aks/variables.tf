variable "name" {
  description = "Cluster name."
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

variable "subnet_id" {
  description = "Subnet for AKS nodes."
  type        = string
}

variable "acr_name" {
  description = "Globally unique container registry name (alphanumeric only)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Null uses the AKS default."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "AKS control plane tier: Free, Standard or Premium."
  type        = string
  default     = "Free"
}

variable "node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_min_count" {
  description = "Minimum nodes for the autoscaler."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes for the autoscaler."
  type        = number
  default     = 3
}

variable "tenant_id" {
  description = "Entra tenant that authenticates cluster users."
  type        = string
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server. AKS treats an empty list as open to the internet, so one is required."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0
    error_message = "List at least one CIDR, such as your IP and CI's egress range."
  }
}

variable "admin_principal_ids" {
  description = "Entra object IDs granted cluster admin through Azure RBAC."
  type        = set(string)
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
