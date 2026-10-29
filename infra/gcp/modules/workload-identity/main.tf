# ==================== Workload Identity Federation for GKE ====================
# No Google service accounts and no Kubernetes service account annotations: each Kubernetes service
# account is an IAM principal of the cluster's workload pool in its own right, and resources grant
# roles to it directly. This mirrors Azure's identities, keyed the same way (apps, external-secrets).
# The pool is per project, so a service account with the same namespace and name in another cluster
# of this project gets the same access; keep one cluster per project or use distinct namespaces.
locals {
  pool = "${var.project_id}.svc.id.goog"

  principals = {
    for id, cfg in var.identities : id => {
      for sa in cfg.service_accounts :
      sa => "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${local.pool}/subject/ns/${cfg.namespace}/sa/${sa}"
    }
  }
}
