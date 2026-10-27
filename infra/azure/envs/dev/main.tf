# ==================== Locals ====================
locals {
  name = "${var.project}-${var.environment}"
  # Globally unique names (Key Vault, ACR, Postgres, Service Bus, Redis) get a stable random suffix.
  unique = "${var.project}${var.environment}${random_string.suffix.result}"

  tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  app_namespace = "sprocketry"
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# ==================== Network ====================
module "network" {
  source              = "../../modules/network"
  name                = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# ==================== Compute ====================
module "aks" {
  source              = "../../modules/aks"
  name                = "aks-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = module.network.aks_subnet_id
  acr_name            = "acr${local.unique}"
  node_vm_size        = var.node_vm_size
  node_max_count      = var.node_max_count
  tags                = local.tags
}

# ==================== Data ====================
module "postgres" {
  source              = "../../modules/postgres"
  name                = "psql-${local.unique}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = module.network.postgres_subnet_id
  private_dns_zone_id = module.network.postgres_private_dns_zone_id
  databases           = ["catalog", "shipping"]
  tags                = local.tags

  # The server can only be created once its private DNS zone is linked to the VNet.
  depends_on = [module.network]
}

module "redis" {
  source              = "../../modules/redis"
  name                = "redis-${local.unique}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# ==================== Messaging ====================
module "servicebus" {
  source              = "../../modules/servicebus"
  name                = "sb-${local.unique}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  topics              = { orders = ["fulfillment"] }
  tags                = local.tags
}

# ==================== Secrets ====================
# Key Vault is the single source of truth. External Secrets Operator syncs these into Kubernetes.
module "keyvault" {
  source              = "../../modules/keyvault"
  name                = "kv-${local.unique}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  secrets = {
    "catalog-database-url"  = module.postgres.connection_strings["catalog"]
    "shipping-database-url" = module.postgres.connection_strings["shipping"]
    "redis-host"            = module.redis.host
    "redis-password"        = module.redis.primary_access_key
  }
}

# ==================== Workload Identity ====================
module "workload_identity" {
  source              = "../../modules/workload-identity"
  name_prefix         = "id-${local.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  oidc_issuer_url     = module.aks.oidc_issuer_url
  tags                = local.tags

  identities = {
    # Used by the Dapr sidecars of the services that publish or consume events.
    apps = {
      namespace        = local.app_namespace
      service_accounts = ["payment", "fulfillment"]
    }
    # Used by External Secrets Operator to read Key Vault.
    external-secrets = {
      namespace        = "external-secrets"
      service_accounts = ["external-secrets"]
    }
  }
}

resource "azurerm_role_assignment" "apps_servicebus_sender" {
  scope                = module.servicebus.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = module.workload_identity.principal_ids["apps"]
}

resource "azurerm_role_assignment" "apps_servicebus_receiver" {
  scope                = module.servicebus.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = module.workload_identity.principal_ids["apps"]
}

resource "azurerm_role_assignment" "eso_keyvault_reader" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.workload_identity.principal_ids["external-secrets"]
}

data "azurerm_client_config" "current" {}
