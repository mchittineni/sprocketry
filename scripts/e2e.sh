#!/usr/bin/env bash
# End-to-end checks against the running local stack (`make up`), through the real Dapr sidecars,
# Valkey and Postgres: cart concurrency, stock limits, and that a checkout submitted twice places one
# order. Needs the stack running with PAYMENT_FAILURE_RATE=0.
set -euo pipefail

CURL_IMAGE=${CURL_IMAGE:-curlimages/curl:8.17.0}
STOREFRONT=$(docker compose ps -q storefront)
[ -n "$STOREFRONT" ] || { echo "The local stack is not running; start it with 'make up'." >&2; exit 2; }

# The checks run in the storefront's network namespace, so localhost:3500 is its Dapr sidecar,
# exactly the path the storefront itself uses.
output=$(docker run --rm -i --network "container:$STOREFRONT" "$CURL_IMAGE" sh -s <<'EOF'
set -u
D=http://localhost:3500/v1.0/invoke
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; failed=1; fi; }
status() { curl -s -o /tmp/body -w '%{http_code}' "$@"; }
add() { status -X POST -H 'content-type: application/json' -d "{\"sku\":\"$2\",\"quantity\":$3}" "$D/cart/method/cart/$1/items"; }
units() { curl -s "$D/cart/method/cart/$1" | grep -o '"quantity":[0-9]*' | cut -d: -f2 | awk '{n+=$1} END {print n+0}'; }
stock() { curl -s "$D/catalog/method/products/$1" | grep -o '"stock":[0-9]*' | cut -d: -f2; }

i=0
until curl -sf -o /dev/null "$D/catalog/method/products/RB-002" && curl -sf -o /dev/null "$D/cart/method/cart/probe" \
  && curl -sf -o /dev/null "$D/shipping/method/quote/1"; do
  i=$((i + 1)); [ $i -lt 90 ] || { echo "FAIL services did not become ready"; exit 1; }; sleep 2
done

run=$(date +%s)-$$
c="e2e-$run"
check "add to a new cart" 200 "$(add "$c" RB-002 2)"
check "missing sku is rejected" 400 "$(status -X POST -H 'content-type: application/json' -d '{"quantity":1}' "$D/cart/method/cart/$c/items")"
check "adding more than stock is refused" 409 "$(add "$c" RB-004 9)"
check "set quantity" 200 "$(status -X PUT -H 'content-type: application/json' -d '{"quantity":3}' "$D/cart/method/cart/$c/items/RB-002")"
check "quantity after set" 3 "$(units "$c")"

# Concurrent writes to one cart, starting from a cart that doesn't exist yet. Several carts, so a lucky
# schedule can't hide a lost or refused write.
n=0
for k in 1 2 3; do
  for s in RB-001 RB-002 RB-003 RB-005 RB-001 RB-002 RB-003 RB-005; do
    n=$((n + 1)); { add "e2e-fresh-$k-$run" "$s" 1; echo; } > "/tmp/code-$n" &
  done
done
wait
check "concurrent adds all succeed" 0 "$(cat /tmp/code-* | grep -vc '^200$')"
check "concurrent adds are all kept" "8 8 8" "$(units "e2e-fresh-1-$run") $(units "e2e-fresh-2-$run") $(units "e2e-fresh-3-$run")"

# The same cart paid for twice at once must take stock once and produce one order ID.
before=$(stock RB-002)
for n in 1 2; do
  curl -s -X POST -H 'content-type: application/json' -d '{"user_id":"e2e","city_id":1}' "$D/payment/method/pay/$c" > "/tmp/pay-$n" &
done
wait
id1=$(grep -o '"order_id":"[^"]*"' /tmp/pay-1 | cut -d'"' -f4)
id2=$(grep -o '"order_id":"[^"]*"' /tmp/pay-2 | cut -d'"' -f4)
[ -n "$id1" ] || { echo "FAIL checkout: $(cat /tmp/pay-1)"; failed=1; }
check "double checkout gets one order ID" "$id1" "$id2"
check "stock is taken once" $((before - 3)) "$(stock RB-002)"
check "cart is cleared" 0 "$(units "$c")"
echo "ORDER_ID=$id1"
exit $failed
EOF
) && status=0 || status=$?
echo "$output" | grep -v '^ORDER_ID='

# Fulfillment must dispatch the order once, even though it was published twice.
order=$(sed -n 's/^ORDER_ID=//p' <<<"$output")
if [ -n "$order" ]; then
  for _ in $(seq 1 15); do
    dispatched=$(docker compose logs fulfillment 2>/dev/null | grep -c "\"order dispatched\".*$order" || true)
    [ "$dispatched" -gt 0 ] && break
    sleep 1
  done
  if [ "$dispatched" = 1 ]; then echo "ok   order dispatched once"; else echo "FAIL order dispatched $dispatched times"; status=1; fi
fi
exit "$status"
