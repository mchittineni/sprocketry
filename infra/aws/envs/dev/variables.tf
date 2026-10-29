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
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.37"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes."
  type        = string
  default     = "t3.xlarge"
}

variable "node_max_count" {
  description = "Maximum EKS nodes."
  type        = number
  default     = 3
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EKS API from the internet: your IP and CI's egress range. Requests still
    need an IAM identity with an access entry. Empty makes the endpoint private-only, reachable from
    inside the VPC alone.
  EOT
  type        = list(string)
}

variable "deployer_principal_arns" {
  description = <<-EOT
    IAM user or role ARNs of everyone who runs Terraform or kubectl for this environment: people, SSO
    permission-set roles and the CI role. They get EKS cluster admin. Left empty, it falls back to the
    role of whoever runs Terraform, which only suits one person with no CI plan.
  EOT
  type        = list(string)
  default     = []
}
