variable "name" {
  description = "Replication group ID, also used to name its subnet and security groups."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the cache subnet group."
  type        = list(string)
}

variable "allowed_security_groups" {
  description = "Security groups allowed to connect, keyed by a static label (the IDs are unknown until apply)."
  type        = map(string)
}

variable "engine_version" {
  description = "Valkey major.minor version."
  type        = string
  default     = "9.0"
}

variable "node_type" {
  description = "Cache node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "replicas" {
  description = "Read replicas. 0 for dev; 1 or more enables automatic failover across AZs."
  type        = number
  default     = 0
}

variable "port" {
  description = "Port Valkey listens on."
  type        = number
  default     = 6379
}
