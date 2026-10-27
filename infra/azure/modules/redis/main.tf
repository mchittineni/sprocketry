# ==================== Azure Managed Redis ====================
# Azure Managed Redis replaces the retiring Azure Cache for Redis.
resource "azurerm_managed_redis" "this" {
  name                      = var.name
  location                  = var.location
  resource_group_name       = var.resource_group_name
  sku_name                  = var.sku_name
  high_availability_enabled = var.high_availability_enabled
  tags                      = var.tags

  default_database {
    access_keys_authentication_enabled = true
    # EnterpriseCluster exposes a single endpoint, so non-cluster-aware clients like Dapr work unchanged.
    clustering_policy = "EnterpriseCluster"
    eviction_policy   = "VolatileLRU"
  }
}
