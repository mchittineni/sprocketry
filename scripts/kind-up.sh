#!/usr/bin/env bash
# Runs the whole app on a local kind cluster: Dapr, in-cluster Postgres and Valkey, and the Helm chart.
# Needs Docker, kind, kubectl and helm. No cloud account.
set -euo pipefail

CLUSTER=${CLUSTER:-sprocketry}
DAPR_VERSION=${DAPR_VERSION:-1.18.9}
REGISTRY=${REGISTRY:-ghcr.io/mchittineni/sprocketry}
TAG=${TAG:-dev}
SERVICES=(storefront catalog cart shipping payment fulfillment)

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config deploy/kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER"

helm repo add dapr https://dapr.github.io/helm-charts --force-update
helm upgrade --install dapr dapr/dapr --version "$DAPR_VERSION" \
  -n dapr-system --create-namespace --wait

# Build with compose so image names match values-local.yaml, then copy them into the node.
REGISTRY=$REGISTRY TAG=$TAG docker compose build "${SERVICES[@]}"
for s in "${SERVICES[@]}"; do
  kind load docker-image "$REGISTRY/$s:$TAG" --name "$CLUSTER"
done

helm upgrade --install sprocketry deploy/helm/sprocketry \
  -n sprocketry --create-namespace \
  -f deploy/helm/sprocketry/values-local.yaml \
  --set image.registry="$REGISTRY" --set image.tag="$TAG" \
  --wait --timeout 10m

echo "Storefront: http://localhost:8080"
