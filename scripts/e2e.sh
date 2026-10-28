#!/usr/bin/env bash
# End-to-end checks against the running local stack (`make up`), through the real Dapr sidecars,
# Valkey, Postgres, Keycloak and flagd: cart concurrency, stock limits, that a checkout submitted twice
# places one order, that fault flags apply at runtime, signing in through the storefront, and that reviews
# and profile accept only valid tokens. Needs the stack running with every fault off (scripts/fault.sh reset).
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

host_check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; status=1; fi; }

# ---------- Fault flags ----------
# A fault switched on takes effect without restarting payment, and switching it off restores checkout.
checkout() {
  docker run --rm --network "container:$STOREFRONT" -e C="e2e-fault-$(date +%s)-$RANDOM" "$CURL_IMAGE" sh -c '
    D=http://localhost:3500/v1.0/invoke
    curl -s -o /dev/null -X POST -H "content-type: application/json" -d "{\"sku\":\"RB-005\",\"quantity\":1}" "$D/cart/method/cart/$C/items"
    curl -s -o /dev/null -w "%{http_code}" -X POST -H "content-type: application/json" -d "{\"user_id\":\"e2e\",\"city_id\":1}" "$D/payment/method/pay/$C"'
}
# Polls, since flagd and then payment's copy of the flags take a moment to pick the change up.
checkout_until() { for _ in $(seq 1 15); do got=$(checkout); [ "$got" = "$1" ] && break; sleep 1; done; echo "$got"; }
trap './scripts/fault.sh reset >/dev/null' EXIT
./scripts/fault.sh payment-failure-rate all >/dev/null
host_check "fault flag fails checkouts at runtime" 502 "$(checkout_until 502)"
./scripts/fault.sh reset >/dev/null
host_check "clearing the fault restores checkout" 200 "$(checkout_until 200)"
trap - EXIT

# ---------- Identity ----------
# A throwaway shopper, and a throwaway client that may exchange a password for a token, so the services
# can be called with real Keycloak tokens. The storefront's own client allows only the browser flow.
KC=http://localhost:${KEYCLOAK_PORT:-8081}
SF=http://localhost:${STOREFRONT_PORT:-3000}
run=$(date +%s)-$$
user=e2e-$run
pass=Pw-$run-x9
client=e2e-$run
# The first value of a JSON field; good enough for the flat answers used here.
json_field() { grep -o "\"$1\":\"\{0,1\}[^\",}]*" | head -1 | sed 's/^[^:]*:"\{0,1\}//'; }

admin_token() {
  curl -s -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
    "$KC/realms/master/protocol/openid-connect/token" | json_field access_token
}
kc() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(admin_token)" -H 'content-type: application/json' "$@"; }
cleanup() {
  for kind in users clients; do
    field=$([ "$kind" = users ] && echo username || echo clientId)
    id=$(curl -s -H "Authorization: Bearer $(admin_token)" "$KC/admin/realms/sprocketry/$kind?$field=e2e-$run&exact=true" | json_field id)
    if [ -n "$id" ]; then kc -X DELETE "$KC/admin/realms/sprocketry/$kind/$id" >/dev/null; fi
  done
}
trap cleanup EXIT

# Keycloak and the storefront start slower than the services checked above; on a fresh stack they may
# still be coming up.
for _ in $(seq 1 90); do
  curl -sf -o /dev/null "$KC/realms/sprocketry/.well-known/openid-configuration" && curl -sf -o /dev/null "$SF/" && break
  sleep 2
done

host_check "create test shopper" 201 "$(kc -X POST "$KC/admin/realms/sprocketry/users" -d '{"username":"'"$user"'","email":"'"$user"'@example.test","firstName":"E2E","lastName":"Shopper","enabled":true,"emailVerified":true,"credentials":[{"type":"password","value":"'"$pass"'","temporary":false}]}')"
host_check "create test client" 201 "$(kc -X POST "$KC/admin/realms/sprocketry/clients" -d '{"clientId":"'"$client"'","secret":"'"$client"'-secret","publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":true,"protocolMappers":[{"name":"audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"sprocketry-api","access.token.claim":"true"}}]}')"
token=$(curl -s -d client_id="$client" -d client_secret="$client-secret" -d username="$user" -d password="$pass" \
  -d grant_type=password -d scope=openid "$KC/realms/sprocketry/protocol/openid-connect/token" | json_field access_token)
wrong_issuer=$(admin_token)

ids=$(docker run --rm -i --network "container:$STOREFRONT" -e TOKEN="$token" -e WRONG="$wrong_issuer" "$CURL_IMAGE" sh -s <<'EOF'
set -u
D=http://localhost:3500/v1.0/invoke
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; failed=1; fi; }
status() { curl -s -o /tmp/body -w '%{http_code}' "$@"; }
post() { status -X POST -H 'content-type: application/json' "$@"; }

i=0
until curl -sf -o /dev/null "$D/reviews/method/products/RB-001/reviews" && [ "$(status "$D/profile/method/me")" = 401 ]; do
  i=$((i + 1)); [ $i -lt 90 ] || { echo "FAIL reviews and profile did not become ready"; exit 1; }; sleep 2
done

review='{"rating":4,"body":"Lifts more than the brochure says."}'
check "review without a token is refused" 401 "$(post -d "$review" "$D/reviews/method/products/RB-001/reviews")"
check "review with another realm's token is refused" 401 "$(post -H "authorization: Bearer $WRONG" -d "$review" "$D/reviews/method/products/RB-001/reviews")"
check "review is posted" 201 "$(post -H "authorization: Bearer $TOKEN" -d "$review" "$D/reviews/method/products/RB-001/reviews")"
check "review shows the shopper's name" 1 "$(grep -c '"author":"E2E Shopper"' /tmp/body)"
check "second review of the same robot is refused" 409 "$(post -H "authorization: Bearer $TOKEN" -d "$review" "$D/reviews/method/products/RB-001/reviews")"
check "review of an unknown robot is refused" 404 "$(post -H "authorization: Bearer $TOKEN" -d "$review" "$D/reviews/method/products/NOPE/reviews")"
check "reviews are public" 200 "$(status "$D/reviews/method/products/RB-001/reviews")"

check "profile needs a token" 401 "$(status "$D/profile/method/me")"
check "profile defaults to the token's name" 1 "$(status -H "authorization: Bearer $TOKEN" "$D/profile/method/me" >/dev/null; grep -c '"displayName":"E2E Shopper"' /tmp/body)"
check "profile refuses an unknown city" 400 "$(status -X PUT -H 'content-type: application/json' -H "authorization: Bearer $TOKEN" -d '{"displayName":"Eve","defaultCityId":9999}' "$D/profile/method/me")"
check "profile saves name and city" 200 "$(status -X PUT -H 'content-type: application/json' -H "authorization: Bearer $TOKEN" -d '{"displayName":"Eve","defaultCityId":1}' "$D/profile/method/me")"
check "profile keeps the default city" 1 "$(status -H "authorization: Bearer $TOKEN" "$D/profile/method/me" >/dev/null; grep -c '"defaultCityId":1' /tmp/body)"
exit $failed
EOF
) && echo "$ids" || { echo "$ids"; status=1; }

# The browser flow: storefront → Keycloak's login form → back to the storefront, signed in.
jar=$(mktemp)
web() { curl -s -c "$jar" -b "$jar" "$@"; }
login_url=$(web -o /dev/null -w '%{redirect_url}' "$SF/auth/login?returnTo=/account")
host_check "sign-in goes to Keycloak" "$KC/realms/sprocketry/protocol/openid-connect/auth" "${login_url%%\?*}"
form=$(web "$login_url" | grep -o '<form[^>]*kc-form-login[^>]*>' || true)
action=$(sed -n 's/.*action="\([^"]*\)".*/\1/p' <<<"$form" | sed 's/&amp;/\&/g')
callback=$(web -o /dev/null -w '%{redirect_url}' --data-urlencode "username=$user" --data-urlencode "password=$pass" "$action")
host_check "Keycloak returns to the storefront" "$SF/auth/callback" "${callback%%\?*}"
host_check "callback returns to the requested page" "$SF/account" "$(web -o /dev/null -w '%{redirect_url}' "$callback")"
host_check "account page shows the saved profile" 1 "$(web "$SF/account" | grep -c 'value="Eve"' || true)"
host_check "sign-out ends the Keycloak session too" "$KC/realms/sprocketry/protocol/openid-connect/logout" "$(web -o /dev/null -w '%{redirect_url}' "$SF/auth/logout" | sed 's/?.*//')"
host_check "account page needs sign-in again" "$SF/auth/login?returnTo=%2Faccount" "$(web -o /dev/null -w '%{redirect_url}' "$SF/account")"
rm -f "$jar"
exit "$status"
