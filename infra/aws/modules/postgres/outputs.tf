output "address" {
  value = aws_db_instance.this.address
}

# Connection string per database, consumed by Secrets Manager.
output "connection_strings" {
  value = {
    for db in var.databases :
    db => "postgres://${var.admin_login}:${random_password.admin.result}@${aws_db_instance.this.address}:5432/${db}?sslmode=require"
  }
  sensitive = true
}

# JDBC form of each database's address, for Java services such as Keycloak. Credentials are separate.
output "jdbc_urls" {
  value = {
    for db in var.databases :
    db => "jdbc:postgresql://${aws_db_instance.this.address}:5432/${db}?sslmode=require"
  }
}

output "admin_login" {
  value = var.admin_login
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
