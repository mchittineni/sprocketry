output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

# Connection string per database, consumed by Key Vault.
output "connection_strings" {
  value = {
    for db in var.databases :
    db => "postgres://${var.admin_login}:${random_password.admin.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${db}?sslmode=require"
  }
  sensitive = true
}
