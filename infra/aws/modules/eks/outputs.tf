output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

# EKS attaches this group to the control plane and to managed nodes, so it identifies pod traffic too.
output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# The registry host, e.g. 123456789012.dkr.ecr.eu-west-2.amazonaws.com.
output "ecr_registry" {
  value = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}
