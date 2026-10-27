#!/usr/bin/env bash
# One-time: creates the storage account that holds Terraform state (matches envs/*/versions.tf).
set -euo pipefail

RG=${RG:-rg-terraform-state}
ACCOUNT=${ACCOUNT:-tfstatesprocketry}
LOCATION=${LOCATION:-uksouth}

az group create -n "$RG" -l "$LOCATION" -o none
az storage account create -n "$ACCOUNT" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false -o none
az storage container create -n tfstate --account-name "$ACCOUNT" --auth-mode login -o none

# Grant yourself data-plane access, since the backend uses Entra ID instead of account keys.
az role assignment create --role "Storage Blob Data Contributor" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az storage account show -n "$ACCOUNT" -g "$RG" --query id -o tsv)" -o none

echo "State backend ready: $ACCOUNT/tfstate"
