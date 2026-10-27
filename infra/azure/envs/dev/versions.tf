# ==================== Terraform Configuration ====================
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # State lives in Azure Blob Storage. scripts/bootstrap-tfstate.sh creates a uniquely named
  # account and writes backend.hcl, so initialise with `terraform init -backend-config=backend.hcl`.
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "sprocketry/dev.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}
