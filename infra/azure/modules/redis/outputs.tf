output "host" {
  value = "${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port}"
}

output "primary_access_key" {
  value     = azurerm_managed_redis.this.default_database[0].primary_access_key
  sensitive = true
}
