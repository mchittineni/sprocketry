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
