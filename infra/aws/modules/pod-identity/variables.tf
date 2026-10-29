variable "name_prefix" {
  description = "Prefix for IAM role names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the service accounts live in."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of that cluster, to scope the roles' trust policy."
  type        = string
}

variable "identities" {
  description = "Identity name to the namespace and service accounts allowed to use it, and its IAM policy JSON."
  type = map(object({
    namespace        = string
    service_accounts = list(string)
    policy           = string
  }))
}
