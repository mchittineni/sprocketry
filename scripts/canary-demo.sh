#!/usr/bin/env bash
# Rehearses canary releases of payment on the kind cluster (make kind-up):
#   1. a bad release: an image tagged "faulty", which the shipped fault flags fail on every checkout.
#      The canary analysis sees its errors and Argo Rollouts rolls it back on its own.
#   2. reverting it, as you would revert the commit: back to the stable version at once.
#   3. a good release, which steps through the canary weights and is promoted.
# Checkouts run throughout, sent from the storefront's sidecar. Takes about ten minutes.
set -euo pipefail

CLUSTER=${CLUSTER:-sprocketry}
NAMESPACE=${NAMESPACE:-sprocketry}
REGISTRY=${REGISTRY:-ghcr.io/mchittineni/sprocketry}
STABLE=${TAG:-dev}
CHART=deploy/helm/sprocketry
k() { kubectl -n "$NAMESPACE" "$@"; }

phase() { k get rollout payment -o jsonpath='{.status.phase}'; }
wait_phase() {
  for _ in $(seq 1 120); do
    [ "$(phase)" = "$1" ] && return 0
    sleep 5
  done
  echo "payment did not reach $1: $(k get rollout payment -o jsonpath='{.status.message}')" >&2
  return 1
}
release() {
  echo "==> Releasing payment:$1"
  docker tag "$REGISTRY/payment:$STABLE" "$REGISTRY/payment:$1"
  kind load docker-image "$REGISTRY/payment:$1" --name "$CLUSTER" >/dev/null
  helm upgrade sprocketry "$CHART" -n "$NAMESPACE" --reuse-values --set "services.payment.tag=$1" >/dev/null
}

# Checkouts of carts that don't exist: the stable version refuses them (400, not an error), so no stock
# is used up, while a faulty version fails them (502) before it looks at the cart.
storefront=$(k get pod -l app.kubernetes.io/name=storefront -o name | head -1)
# kubectl directly, not through k(), so $! is kubectl itself and the trap below stops it. The storefront
# image is distroless: node is at /nodejs/bin/node.
kubectl -n "$NAMESPACE" exec "$storefront" -c storefront -- /nodejs/bin/node -e '
  const end = Date.now() + 20 * 60 * 1000;
  (async () => {
    for (let n = 0; Date.now() < end; n++) {
      await fetch(`http://localhost:3500/v1.0/invoke/payment/method/pay/canary-demo-${n}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user_id: "demo", city_id: 1 }),
      }).catch(() => {});
      await new Promise((r) => setTimeout(r, 200));
    }
  })();' &
traffic=$!
trap 'kill $traffic 2>/dev/null || true' EXIT

release faulty
wait_phase Degraded
echo "    rolled back: $(k get rollout payment -o jsonpath='{.status.message}')"
k get analysisrun --sort-by=.metadata.creationTimestamp -o custom-columns=ANALYSIS:.metadata.name,PHASE:.status.phase,MESSAGE:.status.message | tail -1

echo "==> Reverting to payment:$STABLE"
helm upgrade sprocketry "$CHART" -n "$NAMESPACE" --reuse-values --set "services.payment.tag=$STABLE" >/dev/null
wait_phase Healthy

release "canary-demo-$(date +%s)"
# Healthy until the controller notices the new version, so wait for the release to start first.
wait_phase Progressing
wait_phase Healthy
echo "    promoted: payment runs $(k get rollout payment -o jsonpath='{.spec.template.spec.containers[0].image}')"
