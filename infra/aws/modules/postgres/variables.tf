variable "name" {
  description = "DB instance identifier, also used to name its subnet and security groups."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group (at least two AZs)."
  type        = list(string)
}

variable "allowed_security_groups" {
  description = "Security groups allowed to connect on 5432, keyed by a static label (the IDs are unknown until apply)."
  type        = map(string)
}

variable "databases" {
  description = "Databases the services need. RDS creates the first; the rest must be created in-cluster."
  type        = list(string)

  validation {
    condition     = length(var.databases) > 0
    error_message = "At least one database is required."
  }
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "18"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage size in GiB."
  type        = number
  default     = 20
}

variable "admin_login" {
  description = "Master username."
  type        = string
  default     = "sprocketryadmin"
}
