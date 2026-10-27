# ==================== PostgreSQL Flexible Server ====================
resource "random_password" "admin" {
  length  = 32
  special = false # keeps the password URL-safe for connection strings
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  version                       = var.postgres_version
  sku_name                      = var.sku_name
  storage_mb                    = var.storage_mb
  zone                          = "1"
  backup_retention_days         = 7
  delegated_subnet_id           = var.subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false
  administrator_login           = var.admin_login
  administrator_password        = random_password.admin.result
  tags                          = var.tags

  authentication {
    password_auth_enabled = true
  }
}

# One database per service that owns data.
resource "azurerm_postgresql_flexible_server_database" "this" {
  for_each  = toset(var.databases)
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
