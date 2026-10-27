# ==================== AKS Cluster ====================
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  # Workload identity lets pods exchange a Kubernetes token for an Entra ID token, so no secrets in pods.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  default_node_pool {
    name                 = "system"
    vm_size              = var.node_vm_size
    vnet_subnet_id       = var.subnet_id
    os_sku               = "AzureLinux"
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }

  tags = var.tags
}

# ==================== Container Registry ====================
resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# ==================== Dapr (managed AKS extension) ====================
resource "azurerm_kubernetes_cluster_extension" "dapr" {
  name           = "dapr"
  cluster_id     = azurerm_kubernetes_cluster.this.id
  extension_type = "Microsoft.Dapr"
  release_train  = "Stable"

  configuration_settings = {
    "global.ha.enabled" = "false"
  }
}
