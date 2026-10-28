#!/usr/bin/env bash
# Runs the whole app on a local kind cluster: Dapr, in-cluster Postgres and Valkey, and the Helm chart.
# Needs Docker, kind, kubectl and helm. No cloud account.
set -euo pipefail

CLUSTER=${CLUSTER:-sprocketry}
DAPR_VERSION=${DAPR_VERSION:-1.18.9}
ARGO_ROLLOUTS_CHART_VERSION=${ARGO_ROLLOUTS_CHART_VERSION:-2.43.7}
REGISTRY=${REGISTRY:-ghcr.io/mchittineni/sprocketry}
TAG=${TAG:-dev}
SERVICES=(storefront catalog cart shipping payment fulfillment reviews profile)

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config deploy/kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER"

# The reconciler gives Rollouts (canary releases) the <app>-dapr Service that Dapr name resolution uses.
helm repo add dapr https://dapr.github.io/helm-charts --force-update
helm upgrade --install dapr dapr/dapr --version "$DAPR_VERSION" \
  -n dapr-system --create-namespace --wait \
  --set global.argoRolloutServiceReconciler.enabled=true

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argo-rollouts argo/argo-rollouts --version "$ARGO_ROLLOUTS_CHART_VERSION" \
  -n argo-rollouts --create-namespace --wait

# Build with compose so image names match values-local.yaml, then copy them into the node.
REGISTRY=$REGISTRY TAG=$TAG docker compose build "${SERVICES[@]}"
for s in "${SERVICES[@]}"; do
  kind load docker-image "$REGISTRY/$s:$TAG" --name "$CLUSTER"
done

helm upgrade --install sprocketry deploy/helm/sprocketry \
  -n sprocketry --create-namespace \
  -f deploy/helm/sprocketry/values-local.yaml \
  --set image.registry="$REGISTRY" --set image.tag="$TAG" \
  --wait=legacy --timeout 10m
# Helm can't read a Rollout's status, so wait for the services' Rollouts separately.
if kubectl -n sprocketry get rollouts -o name 2>/dev/null | grep -q .; then
  kubectl -n sprocketry wait rollouts --all --for=jsonpath='{.status.phase}'=Healthy --timeout 10m
fi

echo "Storefront: http://localhost:8080"
