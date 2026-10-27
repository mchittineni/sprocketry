# Offline plan tests: azurerm is mocked, so these need no Azure credentials and create nothing.
# Run with `terraform test` (or `make tf-validate`). They prove the configuration plans with the
# pinned provider and that the security settings hold. Real API behaviour still needs a real plan.

mock_provider "azurerm" {
  # Data sources are read during plan, and the provider validates these as UUIDs.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "44444444-4444-4444-4444-444444444444"
    }
  }
}

# AKS can't be planned with a mocked provider: real AKS always returns a kubelet identity, but a mock
# plans the optional-and-computed kubelet_identity block as a known empty list, and test overrides
# only replace unknown values. So the whole-environment runs replace the AKS module with fixed
# outputs, and its own settings are covered by `terraform validate` against the provider schema.
override_module {
  target = module.aks
  outputs = {
    cluster_name     = "aks-sprocketry-dev"
    oidc_issuer_url  = "https://uksouth.oic.prod-aks.azure.com/11111111-1111-1111-1111-111111111111/55555555-5555-5555-5555-555555555555/"
    acr_id           = "/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/rg-sprocketry-dev/providers/Microsoft.ContainerRegistry/registries/acrtest12345"
    acr_login_server = "acrtest12345.azurecr.io"
  }
}

variables {
  subscription_id = "44444444-4444-4444-4444-444444444444"
  owner           = "tests@example.com"
}

# ---------- Whole environment ----------

run "environment_plans_with_explicit_deployers" {
  command = plan

  variables {
    deployer_principal_ids = ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
  }

  assert {
    condition     = azurerm_resource_group.this.name == "rg-sprocketry-dev"
    error_message = "Resource group name should follow rg-<project>-<environment>."
  }

  assert {
    condition     = azurerm_role_assignment.eso_keyvault_reader.role_definition_name == "Key Vault Secrets User"
    error_message = "External Secrets should only be able to read Key Vault secrets."
  }
}

run "environment_plans_with_caller_fallback" {
  command = plan

  variables {
    deployer_principal_ids = []
  }
}

# ---------- Modules ----------

run "keyvault_grants_every_deployer" {
  command = plan

  module {
    source = "../../modules/keyvault"
  }

  variables {
    name                          = "kv-test12345"
    location                      = "uksouth"
    resource_group_name           = "rg-test"
    secrets_officer_principal_ids = ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
    secrets = {
      "catalog-database-url" = "postgres://example"
      "redis-password"       = "example"
    }
  }

  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled
    error_message = "Key Vault must use RBAC, not access policies."
  }

  assert {
    condition     = length(azurerm_role_assignment.secrets_officer) == 2
    error_message = "Each deployer should get Key Vault Secrets Officer."
  }

  assert {
    condition     = length(azurerm_key_vault_secret.this) == 2
    error_message = "Every secret passed in should be written."
  }
}

run "network_uses_v5_service_endpoints_and_zone_id" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    name                = "sprocketry-test"
    location            = "uksouth"
    resource_group_name = "rg-test"
  }

  assert {
    condition     = one(azurerm_subnet.postgres.service_endpoint).service == "Microsoft.Storage"
    error_message = "The Postgres subnet should keep its Microsoft.Storage service endpoint."
  }

  assert {
    condition     = one(azurerm_subnet.postgres.delegation).service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "The Postgres subnet must be delegated to Flexible Server."
  }
}

run "servicebus_is_entra_only" {
  command = plan

  module {
    source = "../../modules/servicebus"
  }

  variables {
    name                = "sb-test12345"
    location            = "uksouth"
    resource_group_name = "rg-test"
    topics              = { orders = ["fulfillment"] }
  }

  assert {
    condition     = !azurerm_servicebus_namespace.this.local_auth_enabled
    error_message = "Service Bus must be Entra-only (no SAS keys)."
  }

  assert {
    condition     = length(azurerm_servicebus_subscription.this) == 1
    error_message = "Each topic subscriber should get a pre-created subscription."
  }
}
