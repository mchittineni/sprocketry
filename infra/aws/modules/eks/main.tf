# ==================== EKS Cluster ====================
data "aws_partition" "current" {}

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Envelope-encrypts Kubernetes Secrets in etcd with a key we control and can audit.
resource "aws_kms_key" "secrets" {
  description             = "${var.name} Kubernetes secrets encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-eks-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# The key keeps its default policy (account-wide IAM control), so the cluster role needs these via IAM.
resource "aws_iam_role_policy" "cluster_kms" {
  name = "kubernetes-secrets-encryption"
  role = aws_iam_role.cluster.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = aws_kms_key.secrets.arn
    }]
  })
}

# A public API endpoint open to non-private CIDRs (AVD-AWS-0040, AVD-AWS-0041; the latter flags even a
# /32): deployers and the bootstrap script run kubectl from outside the VPC. It is limited to
# endpoint_public_access_cidrs and every request still needs an IAM identity with an access entry.
# Pass an empty list to make the endpoint private-only.
# trivy:ignore:AVD-AWS-0040
# trivy:ignore:AVD-AWS-0041
resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Access entries only: cluster access is managed in Terraform below, never through the aws-auth ConfigMap,
  # and the creator gets no hidden admin grant (the deployers list includes them when it should).
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = length(var.endpoint_public_access_cidrs) > 0
    public_access_cidrs     = length(var.endpoint_public_access_cidrs) > 0 ? var.endpoint_public_access_cidrs : null
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  # Audit logs answer "who changed what" in the cluster. The other log types add CloudWatch cost for little in dev.
  enabled_cluster_log_types = ["audit"]

  # Standard support only: an unattended dev cluster past end of standard support is upgraded rather than
  # silently billed six times the hourly control plane price for extended support.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
  ]
}

# Deployers administer the cluster through EKS access entries (the equivalent of AKS RBAC Cluster Admin).
resource "aws_eks_access_entry" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.key].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Hands pods the IAM role of their service account (EKS Pod Identity). Dapr sidecars and External Secrets use it.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
}

# ==================== Node Group ====================
resource "aws_iam_role" "node" {
  name = "${var.name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# IMDSv2 with a hop limit of 1 keeps pods from reaching the node role's credentials through the instance
# metadata service. Pods get AWS access only through Pod Identity.
resource "aws_launch_template" "node" {
  name_prefix = "${var.name}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = [var.node_instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # EKS has no built-in autoscaler: without Cluster Autoscaler or Karpenter, desired_size is the node count.
  scaling_config {
    min_size     = var.node_min_count
    desired_size = var.node_desired_count
    max_size     = var.node_max_count
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  # An autoscaler, once installed, owns the node count.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ==================== Container Registry ====================
# Repositories are named after the services, as CI pushes <registry>/<service>:<sha> and :latest.
# Tags are immutable except `latest` (AVD-AWS-0031 wants no exceptions): CI moves `latest` on every
# push, so plain IMMUTABLE would fail every push after the first. Commit-SHA tags, which CI deploys
# from values-image-tags.yaml, can never be overwritten.
# trivy:ignore:AVD-AWS-0031
resource "aws_ecr_repository" "this" {
  for_each = var.ecr_repositories
  name     = each.key

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  # Lets `terraform destroy` remove repositories that still hold images.
  force_delete = true
}

# Untagged images pile up as `latest` moves. Commit-tagged images are kept for rollbacks.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
