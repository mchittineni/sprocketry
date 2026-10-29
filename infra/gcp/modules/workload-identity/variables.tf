variable "project_id" {
  description = "Project that owns the GKE workload pool (<project_id>.svc.id.goog)."
  type        = string
}

variable "project_number" {
  description = "Numeric ID of the same project; principal identifiers use the number."
  type        = string
}

variable "identities" {
  description = "Identity name to the namespace and service accounts it covers."
  type = map(object({
    namespace        = string
    service_accounts = list(string)
  }))
}
