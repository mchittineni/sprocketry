variable "name" {
  description = "Server name (globally unique)."
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
  description = "Delegated subnet for VNet integration."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone linked to the VNet."
  type        = string
}

variable "databases" {
  description = "Databases to create."
  type        = list(string)
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "18"
}

variable "sku_name" {
  description = "Compute SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Storage size in MB."
  type        = number
  default     = 32768
}

variable "admin_login" {
  description = "Administrator username."
  type        = string
  default     = "sprocketryadmin"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
