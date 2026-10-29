output "role_arns" {
  value = { for k, v in aws_iam_role.this : k => v.arn }
}

# "<identity>/<service account>" => "<namespace>/<service account>", as bound in EKS.
output "associations" {
  value = { for k, v in aws_eks_pod_identity_association.this : k => "${v.namespace}/${v.service_account}" }
}
