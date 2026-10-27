output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "acr_login_server" {
  value = module.aks.acr_login_server
}

output "key_vault_uri" {
  value = module.keyvault.vault_uri
}

output "servicebus_namespace" {
  value = module.servicebus.namespace_fqdn
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

# Feed these into deploy/helm/sprocketry/values-azure.yaml.
output "workload_identity_client_ids" {
  value = module.workload_identity.client_ids
}
