# Identity name to { Kubernetes service account => IAM principal }, to grant roles to.
output "principals" {
  value = local.principals
}
