# ==================== Workload Identities ====================
# One user-assigned identity per entry, federated with one or more Kubernetes service accounts.
resource "azurerm_user_assigned_identity" "this" {
  for_each            = var.identities
  name                = "${var.name_prefix}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  for_each = {
    for pair in flatten([
      for id, cfg in var.identities : [
        for sa in cfg.service_accounts : { identity = id, namespace = cfg.namespace, sa = sa }
      ]
    ]) : "${pair.identity}/${pair.sa}" => pair
  }
  name                = "${each.value.namespace}-${each.value.sa}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this[each.value.identity].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.sa}"
}
