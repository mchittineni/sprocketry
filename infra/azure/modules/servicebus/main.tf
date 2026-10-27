# ==================== Service Bus ====================
resource "azurerm_servicebus_namespace" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard" # topics need Standard or above
  local_auth_enabled  = false      # Entra ID only, no SAS keys
  minimum_tls_version = "1.2"
  tags                = var.tags
}

resource "azurerm_servicebus_topic" "this" {
  for_each     = var.topics
  name         = each.key
  namespace_id = azurerm_servicebus_namespace.this.id
}

# Dapr names each subscription after the consuming app id. Pre-creating them lets
# the apps run with send/receive rights only, not namespace management rights.
resource "azurerm_servicebus_subscription" "this" {
  for_each = {
    for pair in flatten([
      for topic, subs in var.topics : [for sub in subs : { topic = topic, sub = sub }]
    ]) : "${pair.topic}/${pair.sub}" => pair
  }
  name               = each.value.sub
  topic_id           = azurerm_servicebus_topic.this[each.value.topic].id
  max_delivery_count = 10
}
