output "id" {
  value = azurerm_servicebus_namespace.this.id
}

output "namespace_fqdn" {
  value = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
}
