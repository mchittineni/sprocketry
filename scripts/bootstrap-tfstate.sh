#!/usr/bin/env bash
# One-time: creates the storage account that holds Terraform state and writes the
# partial backend config that infra/azure/envs/dev/versions.tf expects.
set -euo pipefail

TF_DIR=${TF_DIR:-infra/azure/envs/dev}
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
echo "Wrote $TF_DIR/backend.hcl. Next: terraform -chdir=$TF_DIR init -backend-config=backend.hcl"
echo "For CI, set repository variables TFSTATE_RESOURCE_GROUP=$RG and TFSTATE_ACCOUNT=$ACCOUNT."
