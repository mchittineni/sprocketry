variable "project_id" {
  description = "Existing GCP project to deploy into."
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

variable "region" {
  description = "GCP region."
  type        = string
  default     = "europe-west2"
}

variable "zone" {
  description = "Zone for the (zonal) GKE cluster."
  type        = string
  default     = "europe-west2-a"
}

variable "owner" {
  description = "Owner label value. Lower-cased, with characters labels don't allow replaced by '_'."
  type        = string
}

variable "node_machine_type" {
  description = "Machine type for GKE nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "node_max_count" {
  description = "Maximum GKE nodes."
  type        = number
  default     = 3
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"
}

variable "master_authorized_cidrs" {
  description = "Public CIDRs allowed to the cluster's IP endpoint. Empty: use the IAM-authorised DNS endpoint."
  type        = list(string)
  default     = []
}

variable "deployer_members" {
  description = <<-EOT
    IAM members of everyone who runs Terraform or deploys here: people, groups and the CI service
    account (user:a@example.com, group:..., serviceAccount:...). They get Kubernetes admin
    (roles/container.admin). Left empty, it falls back to whoever runs Terraform, which only suits
    one person with no CI plan. Running Terraform itself needs project roles granted outside it.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for m in var.deployer_members : can(regex("^(user|group|serviceAccount|principal|principalSet|domain):", m))])
    error_message = "Each deployer must be an IAM member string, e.g. user:a@example.com or serviceAccount:ci@p.iam.gserviceaccount.com."
  }
}
