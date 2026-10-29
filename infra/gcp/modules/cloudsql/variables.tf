variable "name" {
  description = "Instance name. Cloud SQL blocks reusing a name for a week after deletion."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
}

variable "network_id" {
  description = "VPC with Private Service Access configured."
  type        = string
}

variable "allocated_ip_range" {
  description = "Name of the Private Service Access range to allocate from."
  type        = string
}

variable "databases" {
  description = "Databases to create."
  type        = list(string)
}

variable "database_version" {
  description = "Cloud SQL database version."
  type        = string
  default     = "POSTGRES_18"
}

variable "tier" {
  description = "Machine tier. 1 vCPU / 3.75 GB allows 100 connections; the shared-core tiers allow 25-50."
  type        = string
  default     = "db-custom-1-3840"
}

variable "user_name" {
  description = "Built-in database user."
  type        = string
  default     = "sprocketry"
}
