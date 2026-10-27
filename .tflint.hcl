config {
  call_module_type = "all"
}

plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

rule "terraform_unused_declarations" {
  enabled = true
}

# The dev environment is meant to be torn down (`make azure-destroy`, Key Vault purge on destroy),
# so a prevent_destroy lifecycle on data resources would block that. Enable it for long-lived environments.
rule "azurerm_resources_missing_prevent_destroy" {
  enabled = false
}
