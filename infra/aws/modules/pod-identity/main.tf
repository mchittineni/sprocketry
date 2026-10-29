# ==================== Pod Identities ====================
# One IAM role per entry, assumable by the EKS Pod Identity agent for the listed service accounts.
# Unlike IRSA, the service accounts need no annotation: the association below is the whole binding.
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "this" {
  for_each = var.identities
  name     = "${var.name_prefix}-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      # Only this cluster's Pod Identity agent, not one in another cluster or account.
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnEquals    = { "aws:SourceArn" = var.cluster_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  for_each = var.identities
  name     = each.key
  role     = aws_iam_role.this[each.key].id
  policy   = each.value.policy
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = {
    for pair in flatten([
      for id, cfg in var.identities : [
        for sa in cfg.service_accounts : { identity = id, namespace = cfg.namespace, sa = sa }
      ]
    ]) : "${pair.identity}/${pair.sa}" => pair
  }
  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.sa
  role_arn        = aws_iam_role.this[each.value.identity].arn
}
