#!/usr/bin/env bash
# Installs cluster add-ons that the app chart depends on, then hands over to Argo CD.
# Run after `terraform apply` in infra/azure/envs/dev.
set -euo pipefail

TF_DIR=${TF_DIR:-infra/azure/envs/dev}
tf() { terraform -chdir="$TF_DIR" output -raw "$1"; }

RG=$(tf resource_group)
CLUSTER=$(tf aks_cluster_name)
ESO_CLIENT_ID=$(terraform -chdir="$TF_DIR" output -json workload_identity_client_ids | jq -r '."external-secrets"')

az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing

# External Secrets Operator, running as the workload identity that can read Key Vault.
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets \
  --set "serviceAccount.annotations.azure\.workload\.identity/client-id=$ESO_CLIENT_ID" \
  --set "podLabels.azure\.workload\.identity/use=true"

# Envoy Gateway implements the Gateway API for public traffic.
helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  -n envoy-gateway-system --create-namespace --wait
kubectl apply -f deploy/gateway/gateway.yaml

# Argo CD, then the app-of-apps that syncs everything else from Git.
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
kubectl apply -f deploy/argocd/sprocketry.yaml

echo "Bootstrap complete. Argo CD is syncing sprocketry into namespace 'sprocketry'."
