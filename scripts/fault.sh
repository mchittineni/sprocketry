#!/usr/bin/env bash
# Turns fault flags on and off at runtime, without restarting anything:
#   scripts/fault.sh                              list the flags and their variants
#   scripts/fault.sh payment-failure-rate 20pct   serve that variant
#   scripts/fault.sh reset                        every flag back to off
# Changes the local stack when it is running, and otherwise the cluster in the current kubectl context
# (NAMESPACE, default sprocketry). On a cluster Argo CD syncs, change
# deploy/helm/sprocketry/files/flagd/faults.json in Git instead: Argo CD reverts edits made here.
set -euo pipefail

FILE=deploy/helm/sprocketry/files/flagd/faults.json
NAMESPACE=${NAMESPACE:-sprocketry}
CONFIGMAP=flagd-flags

if [ -n "$(docker compose ps -q flagd 2>/dev/null)" ]; then target=compose; else target=cluster; fi

current() {
  if [ "$target" = compose ]; then cat "$FILE"; else kubectl get configmap "$CONFIGMAP" -n "$NAMESPACE" -o jsonpath='{.data.faults\.json}'; fi
}

save() {
  if [ "$target" = compose ]; then
    # Rewritten in place: flagd watches the file and reloads it.
    printf '%s\n' "$1" > "$FILE"
  else
    # The kubelet refreshes the mounted ConfigMap within about a minute, and flagd reloads it.
    kubectl patch configmap "$CONFIGMAP" -n "$NAMESPACE" --type merge \
      -p "$(jq -n --arg flags "$1" '{data: {"faults.json": ($flags + "\n")}}')" >/dev/null
  fi
}

case "${1:-}" in
  "")
    current | jq -r '.flags | to_entries[] | "\(.key): \(.value.defaultVariant)   (\(.value.variants | keys_unsorted | join(", ")))"'
    ;;
  reset)
    # Assigned first so a failure stops the script instead of saving an empty file.
    updated=$(current | jq '.flags[].defaultVariant = "off"')
    save "$updated"
    echo "All faults off ($target)."
    ;;
  *)
    [ $# -eq 2 ] || { echo "usage: $0 [<flag> <variant> | reset]" >&2; exit 2; }
    updated=$(current | jq --arg f "$1" --arg v "$2" '
      if .flags[$f] == null then error("unknown flag \($f)")
      elif .flags[$f].variants[$v] == null then error("\($f) has no variant \($v)")
      else .flags[$f].defaultVariant = $v end')
    save "$updated"
    echo "$1 is now $2 ($target)."
    ;;
esac
