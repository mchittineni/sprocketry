# ==================== Key Vault ====================
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                       = var.name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = var.purge_protection_enabled
  tags                       = var.tags
}

# Lets every deployer (you locally and the CI identity) read and write the secrets below.
# CI's terraform plan must read them to refresh state.
resource "azurerm_role_assignment" "secrets_officer" {
  for_each             = var.secrets_officer_principal_ids
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_key_vault_secret" "this" {
  # Keys are not secret; only values are. for_each cannot iterate a sensitive map directly.
  for_each     = nonsensitive(toset(keys(var.secrets)))
  name         = each.key
  value        = var.secrets[each.key]
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"

  depends_on = [azurerm_role_assignment.secrets_officer]
}
