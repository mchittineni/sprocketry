variable "name" {
  description = "Name prefix for network resources."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
}

variable "nodes_cidr" {
  description = "Primary subnet range, used by GKE nodes."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pods."
  type        = string
  default     = "10.24.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range for Kubernetes Services."
  type        = string
  default     = "10.28.0.0/20"
}

variable "private_services_cidr" {
  description = "Range reserved for Private Service Access (Cloud SQL, Memorystore)."
  type        = string
  default     = "10.32.0.0/16"
}
