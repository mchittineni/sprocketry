#!/usr/bin/env bash
# Runs a Chaos Mesh experiment from deploy/chaos against the kind cluster (make kind-up) and checks its
# hypothesis: steady state first, then the fault, probes while it lasts, and recovery after.
#   scripts/chaos.sh                      list the experiments
#   scripts/chaos.sh <experiment>         run one; exits non-zero if its hypothesis does not hold
# Installs Chaos Mesh on first use. The experiment is removed on exit, even if the run is interrupted.
set -euo pipefail

NAMESPACE=sprocketry
CHAOS_MESH_VERSION=${CHAOS_MESH_VERSION:-2.8.4}
DIR=deploy/chaos
k() { kubectl -n "$NAMESPACE" "$@"; }
# The experiment file's "# Hypothesis:" comment, on one line.
hypothesis() { awk '/^# Hypothesis: /{on=1; sub(/^# Hypothesis: /, "")} /^# Run with/{on=0} on{sub(/^# /, ""); printf "%s ", $0}' "$1"; }

if [ $# -eq 0 ]; then
  for f in "$DIR"/*.yaml; do
    printf '%s\n  %s\n' "$(basename "$f" .yaml)" "$(hypothesis "$f")"
  done
  exit 0
fi
name=$1
file=$DIR/$name.yaml
[ -f "$file" ] || { echo "no experiment $name in $DIR" >&2; exit 2; }
k get rollout cart >/dev/null 2>&1 || { echo "Run make kind-up first: no sprocketry app in the current cluster." >&2; exit 2; }

# kind's nodes run containerd; Chaos Mesh's daemon injects faults through it.
if ! helm status chaos-mesh -n chaos-mesh >/dev/null 2>&1; then
  echo "==> Installing Chaos Mesh $CHAOS_MESH_VERSION"
  helm repo add chaos-mesh https://charts.chaos-mesh.org --force-update >/dev/null
  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh --version "$CHAOS_MESH_VERSION" \
    -n chaos-mesh --create-namespace --wait \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set controllerManager.replicaCount=1 \
    --set dashboard.create=false >/dev/null
fi

# Calls a service through the storefront's Dapr sidecar, as the app does. Prints "<status> <ms> <body>";
# status 0 means no answer within 30 seconds. The storefront image is distroless: node is at /nodejs/bin/node.
storefront=$(k get pod -l app.kubernetes.io/name=storefront -o name | head -1)
call() {
  k exec "$storefront" -c storefront -- /nodejs/bin/node -e '
    const [method, path, body] = process.argv.slice(1);
    const start = Date.now();
    fetch(`http://localhost:3500/v1.0/invoke/${path}`, {
      method, body: body || undefined, headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(30000),
    })
      .then(async (r) => console.log(r.status, Date.now() - start, (await r.text()).replace(/\s+/g, " ")))
      .catch((e) => console.log(0, Date.now() - start, e.name));' "$@"
}
field() { awk -v n="$1" '{print $n}'; }
units() { grep -o '"quantity":[0-9]*' | cut -d: -f2 | awk '{n+=$1} END {print n+0}'; }

failed=0
check() { if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1: $2"; failed=1; fi; }
cleanup() { k delete -f "$file" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

run=$(date +%s)
cart=chaos-$run
add_item() { call POST "cart/method/cart/$cart/items" '{"sku":"RB-005","quantity":2}' | field 1; }
cart_units() { call GET "cart/method/cart/$cart" | cut -d' ' -f3- | units; }
# items[*], not items[0]: while a pod is replaced there may briefly be none.
pod_uid() { k get pod -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[*].metadata.uid}'; }
restarts() { k get pod -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'; }

echo "==> $name: $(hypothesis "$file")"
case "$name" in
  cart-pod-kill)
    [ "$(add_item)" = 200 ] || { echo "steady state: could not fill a cart" >&2; exit 1; }
    before=$(pod_uid cart)
    k apply -f "$file" >/dev/null
    start=$(date +%s)
    for _ in $(seq 1 60); do [ "$(pod_uid cart)" != "$before" ] && break; sleep 1; done
    check "the cart pod was killed and replaced" "$([ "$(pod_uid cart)" != "$before" ] && echo ok || echo "the pod is still $before")"
    for _ in $(seq 1 60); do [ "$(call GET "cart/method/cart/$cart" | field 1)" = 200 ] && break; sleep 2; done
    took=$(( $(date +%s) - start ))
    check "cart answers again within 60s" "$([ "$took" -le 60 ] && echo ok || echo "took ${took}s")"
    echo "     (answered again after ${took}s)"
    check "the cart survived" "$([ "$(cart_units)" = 2 ] && echo ok || echo "it has $(cart_units) units, not 2")"
    ;;

  cart-valkey-partition)
    [ "$(add_item)" = 200 ] || { echo "steady state: could not fill a cart" >&2; exit 1; }
    before=$(restarts cart)
    k apply -f "$file" >/dev/null
    sleep 10
    read -r status ms _ <<<"$(call GET "cart/method/cart/$cart")"
    check "cart fails while Valkey is unreachable" "$([ "$status" != 200 ] && echo ok || echo "it answered 200")"
    check "cart fails within 10s rather than hanging" "$([ "$status" != 0 ] && [ "$ms" -le 10000 ] && echo ok || echo "status $status after ${ms}ms")"
    echo "     (status $status after ${ms}ms)"
    # The partition lasts 45s; then Chaos Mesh removes it.
    k wait -f "$file" --for=jsonpath='{.status.experiment.desiredPhase}'=Stop --timeout 90s >/dev/null
    start=$(date +%s)
    for _ in $(seq 1 30); do [ "$(call GET "cart/method/cart/$cart" | field 1)" = 200 ] && break; sleep 2; done
    took=$(( $(date +%s) - start ))
    check "cart recovers within 60s of the network healing" "$([ "$took" -le 60 ] && echo ok || echo "took ${took}s")"
    echo "     (recovered after ${took}s)"
    check "the cart survived" "$([ "$(cart_units)" = 2 ] && echo ok || echo "it has $(cart_units) units, not 2")"
    check "cart recovered without restarting" "$([ "$(restarts cart)" = "$before" ] && echo ok || echo "restart counts $before -> $(restarts cart)")"
    ;;

  shipping-latency)
    # Checkouts to a city shipping doesn't serve: payment reads the cart and asks shipping for a quote,
    # then refuses (400), so the latency is measured on every call and no stock is used.
    [ "$(add_item)" = 200 ] || { echo "steady state: could not fill a cart" >&2; exit 1; }
    pay() { call POST "payment/method/pay/$cart" '{"user_id":"chaos","city_id":9999}'; }
    read -r status ms _ <<<"$(pay)"
    check "steady state: checkout answers within 1s" "$([ "$status" = 400 ] && [ "$ms" -lt 1000 ] && echo ok || echo "status $status after ${ms}ms")"
    port=19090
    # Background processes run kubectl directly, not through k(), so $! is the process to stop.
    traffic="" forward=""
    trap 'cleanup; kill $traffic $forward 2>/dev/null || true' EXIT
    kubectl -n "$NAMESPACE" port-forward svc/lgtm "$port:9090" >/dev/null 2>&1 &
    forward=$!
    sleep 3
    alert='ALERTS{alertname="LatencyBudgetBurn",alertstate="firing",sloth_service="payment",severity="page"}'
    firing() { curl -s "http://localhost:$port/api/v1/query" --data-urlencode "query=$alert" | grep -c '"alertname"' || true; }
    check "steady state: no payment latency page" "$([ "$(firing)" = 0 ] && echo ok || echo "it is already firing")"

    # Steady checkouts for the alert to measure, sent from the storefront pod.
    kubectl -n "$NAMESPACE" exec "$storefront" -c storefront -- /nodejs/bin/node -e '
      const end = Date.now() + 15 * 60 * 1000;
      (async () => {
        while (Date.now() < end) {
          await fetch(`http://localhost:3500/v1.0/invoke/payment/method/pay/${process.argv[1]}`, {
            method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user_id: "chaos", city_id: 9999 }),
          }).catch(() => {});
          await new Promise((r) => setTimeout(r, 200));
        }
      })();' "$cart" &
    traffic=$!
    before=$(restarts shipping)
    k apply -f "$file" >/dev/null
    sleep 15
    read -r status ms _ <<<"$(pay)"
    check "checkouts slow down with shipping, without failing" "$([ "$status" = 400 ] && [ "$ms" -ge 1000 ] && echo ok || echo "status $status after ${ms}ms")"
    echo "     (a checkout took ${ms}ms)"
    start=$(date +%s)
    for _ in $(seq 1 60); do [ "$(firing)" -gt 0 ] && break; sleep 10; done
    took=$(( $(date +%s) - start ))
    check "payment's latency page fires within 10 minutes" "$([ "$(firing)" -gt 0 ] && echo ok || echo "not firing after ${took}s")"
    [ "$(firing)" -gt 0 ] && echo "     (fired after ${took}s)"
    check "slow shipping is not restarted" "$([ "$(restarts shipping)" = "$before" ] && echo ok || echo "restart counts $before -> $(restarts shipping)")"
    k delete -f "$file" >/dev/null
    sleep 10
    read -r status ms _ <<<"$(pay)"
    check "checkouts are fast again once shipping is" "$([ "$ms" -lt 1000 ] && echo ok || echo "status $status after ${ms}ms")"
    ;;

  *)
    echo "$name has no probes in $0" >&2
    exit 2
    ;;
esac

[ "$failed" = 0 ] && echo "Hypothesis held." || echo "Hypothesis refuted: see FAIL above."
exit "$failed"
