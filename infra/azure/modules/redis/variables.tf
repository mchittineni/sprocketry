variable "name" {
  description = "Managed Redis name."
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

variable "sku_name" {
  description = "Managed Redis SKU."
  type        = string
  default     = "Balanced_B0"
}

variable "high_availability_enabled" {
  description = "Replicate across zones. Disable for dev to halve cost."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
