#!/usr/bin/env bash
# One-time: creates the storage that holds Terraform state and writes the partial backend config that
# infra/$CLOUD/envs/dev/versions.tf expects. CLOUD is azure (default), aws or gcp.
set -euo pipefail

CLOUD=${CLOUD:-azure}
TF_DIR=${TF_DIR:-infra/$CLOUD/envs/dev}

case "$CLOUD" in
  azure)
    RG=${RG:-rg-terraform-state}
    LOCATION=${LOCATION:-uksouth}
    # Storage account names are global, so derive one from the subscription id unless overridden.
    SUBSCRIPTION=$(az account show --query id -o tsv)
    ACCOUNT=${ACCOUNT:-tfstate$(echo "$SUBSCRIPTION" | tr -d '-' | cut -c1-12)}

    az group create -n "$RG" -l "$LOCATION" -o none
    az storage account create -n "$ACCOUNT" -g "$RG" -l "$LOCATION" \
      --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false -o none
    az storage container create -n tfstate --account-name "$ACCOUNT" --auth-mode login -o none

    # Grant yourself data-plane access, since the backend uses Entra ID instead of account keys.
    az role assignment create --role "Storage Blob Data Contributor" \
      --assignee "$(az ad signed-in-user show --query id -o tsv)" \
      --scope "$(az storage account show -n "$ACCOUNT" -g "$RG" --query id -o tsv)" -o none

    cat > "$TF_DIR/backend.hcl" <<EOF
resource_group_name  = "$RG"
storage_account_name = "$ACCOUNT"
EOF
    echo "State backend ready: $ACCOUNT/tfstate"
    echo "For CI, set repository variables TFSTATE_RESOURCE_GROUP=$RG and TFSTATE_ACCOUNT=$ACCOUNT."
    ;;

  aws)
    REGION=${REGION:-eu-west-2}
    # Bucket names are global, so include the account and region unless overridden.
    BUCKET=${BUCKET:-tfstate-$(aws sts get-caller-identity --query Account --output text)-$REGION}

    if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
      # us-east-1 is the default location and refuses to be named as one.
      if [ "$REGION" = us-east-1 ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
      else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
          --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
      fi
    fi
    # Versioning keeps every earlier state; the lock file (use_lockfile) needs no DynamoDB table.
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    cat > "$TF_DIR/backend.hcl" <<EOF
bucket = "$BUCKET"
region = "$REGION"
EOF
    echo "State backend ready: s3://$BUCKET"
    ;;

  gcp)
    PROJECT=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
    LOCATION=${LOCATION:-europe-west2}
    BUCKET=${BUCKET:-$PROJECT-tfstate}

    if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
      gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" --location "$LOCATION" \
        --uniform-bucket-level-access --public-access-prevention
    fi
    # Versioning keeps every earlier state; GCS locks the state itself.
    gcloud storage buckets update "gs://$BUCKET" --versioning

    cat > "$TF_DIR/backend.hcl" <<EOF
bucket = "$BUCKET"
EOF
    echo "State backend ready: gs://$BUCKET"
    ;;

  *)
    echo "CLOUD must be azure, aws or gcp, not $CLOUD" >&2
    exit 2
    ;;
esac

echo "Wrote $TF_DIR/backend.hcl. Next: terraform -chdir=$TF_DIR init -backend-config=backend.hcl"
