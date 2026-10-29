variable "name" {
  description = "Cluster name."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the nodes."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.37"
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Empty makes the endpoint private-only."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM user or role ARNs granted cluster admin through EKS access entries."
  type        = set(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for the node group."
  type        = string
  default     = "t3.xlarge"
}

variable "node_disk_size" {
  description = "Node root volume size in GiB."
  type        = number
  default     = 50
}

variable "node_min_count" {
  description = "Minimum nodes."
  type        = number
  default     = 1
}

variable "node_desired_count" {
  description = "Initial node count. Ignored after creation so an autoscaler can own it."
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum nodes."
  type        = number
  default     = 3
}

variable "ecr_repositories" {
  description = "ECR repositories to create, one per service image."
  type        = set(string)
}
