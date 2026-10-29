# host:port of the primary endpoint, the form Dapr's redisHost expects.
output "host" {
  value = "${aws_elasticache_replication_group.this.primary_endpoint_address}:${var.port}"
}

output "auth_token" {
  value     = random_password.auth.result
  sensitive = true
}
