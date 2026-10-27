output "client_ids" {
  value = { for k, v in azurerm_user_assigned_identity.this : k => v.client_id }
}

output "principal_ids" {
  value = { for k, v in azurerm_user_assigned_identity.this : k => v.principal_id }
}
