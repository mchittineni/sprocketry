# ==================== Terraform Configuration ====================
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # State lives in a GCS bucket. Create one (versioning on, uniform bucket-level access), write
  # `bucket = "<name>"` to backend.hcl, and initialise with `terraform init -backend-config=backend.hcl`.
  backend "gcs" {
    prefix = "sprocketry/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Applied to every resource that supports labels, like Azure's tags.
  default_labels = local.labels
}
