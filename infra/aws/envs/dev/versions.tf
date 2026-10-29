# ==================== Terraform Configuration ====================
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # State lives in S3, locked with an S3 lock file (no DynamoDB table). backend.hcl names the bucket
  # and its region, e.g. `bucket = "sprocketry-tfstate-123456789012"` and `region = "eu-west-2"`;
  # the bucket should be versioned and encrypted. Initialise with `terraform init -backend-config=backend.hcl`.
  backend "s3" {
    key          = "sprocketry/dev.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
