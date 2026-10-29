variable "name" {
  description = "Cluster name, also the prefix for its node service account and firewall rule."
  type        = string
}

variable "project_id" {
  description = "Project that hosts the cluster."
  type        = string
}

variable "region" {
  description = "Region for Artifact Registry."
  type        = string
}

variable "location" {
  description = "Cluster location: a zone for a zonal cluster, or a region."
  type        = string
}

variable "network_id" {
  description = "VPC the cluster joins."
  type        = string
}

variable "subnetwork_id" {
  description = "Subnet for nodes."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for Services."
  type        = string
}

variable "master_ipv4_cidr" {
  description = "/28 for the control plane's private endpoint. Must not overlap the VPC."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "Public CIDRs allowed to the IP endpoint. Empty: use the DNS endpoint instead."
  type        = list(string)
  default     = []
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"
}

variable "node_machine_type" {
  description = "Machine type for the node pool."
  type        = string
  default     = "e2-standard-4"
}

variable "node_min_count" {
  description = "Minimum nodes for the autoscaler (per zone)."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes for the autoscaler (per zone)."
  type        = number
  default     = 3
}

variable "admin_members" {
  description = "IAM members granted Kubernetes admin (roles/container.admin)."
  type        = set(string)
}

variable "repository_id" {
  description = "Artifact Registry repository name."
  type        = string
  default     = "sprocketry"
}
