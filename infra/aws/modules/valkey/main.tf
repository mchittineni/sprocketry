# ==================== ElastiCache for Valkey ====================
# The AUTH token Dapr sends as redisPassword. ElastiCache allows 16-128 printable characters.
resource "random_password" "auth" {
  length  = 64
  special = false
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

# No egress rules: the cache only answers connections, it never opens them.
resource "aws_security_group" "this" {
  name        = "${var.name}-valkey"
  description = "Valkey, reachable from the EKS cluster only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each                     = var.allowed_security_groups
  security_group_id            = aws_security_group.this.id
  description                  = "Valkey from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
}

# Cluster mode disabled: one shard with a single primary endpoint. Dapr's state.redis then runs with
# redisType "node" (its default) and can use multi-key transactions, which cluster mode would split
# across slots. Serverless ElastiCache is cluster-mode only, so it is not used here.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Dapr state store (carts and sessions)"
  engine               = "valkey"
  engine_version       = var.engine_version
  node_type            = var.node_type
  port                 = var.port

  # One node keeps dev cheap. Raise to 2+ with automatic failover for anything long-lived.
  num_cache_clusters         = var.replicas + 1
  automatic_failover_enabled = var.replicas > 0
  multi_az_enabled           = var.replicas > 0

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  at_rest_encryption_enabled = true
  # TLS is mandatory: plaintext connections are refused, and AUTH requires TLS anyway.
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = random_password.auth.result

  # Carts are worth a day of snapshots; sessions just mean signing in again.
  snapshot_retention_limit = 1
  apply_immediately        = true
}
