variable "name" {
  description = "Instance name."
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

variable "reserved_ip_range" {
  description = "Name of the Private Service Access range to allocate from."
  type        = string
}

variable "tier" {
  description = "BASIC (single node) or STANDARD_HA (replicated). BASIC halves cost in dev."
  type        = string
  default     = "BASIC"
}

variable "memory_size_gb" {
  description = "Capacity in GB."
  type        = number
  default     = 1
}

variable "redis_version" {
  description = "Redis version."
  type        = string
  default     = "REDIS_7_2"
}
