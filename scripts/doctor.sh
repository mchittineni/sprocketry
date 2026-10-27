#!/usr/bin/env bash
# Checks the tools each way of running Sprocketry needs, and says how to get what is missing.
# Usage: scripts/doctor.sh [local|kind|azure|all]   (default: local)
set -uo pipefail

TARGET=${1:-local}
failed=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; failed=1; }
warn() { printf '  \033[33m!\033[0m %s\n      %s\n' "$1" "$2"; }

need() { # need <command> <install hint>
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else bad "$1 not found" "$2"; fi
}

port_free() { # port_free <port> <used by>
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
    warn "port $1 is in use" "$2 needs it. Stop whatever is listening, or run 'make down'/'make kind-down'."
  else
    ok "port $1 free"
  fi
}

# version_ge <have> <want>
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }

check_docker() {
  need docker "https://docs.docker.com/get-docker/"
  if docker info >/dev/null 2>&1; then ok "docker daemon running"; else bad "docker daemon not reachable" "Start Docker Desktop, or the docker service."; fi
  if docker compose version >/dev/null 2>&1; then ok "docker compose v2"; else bad "docker compose v2 missing" "Update Docker, or install the compose plugin."; fi
}

check_local() {
  echo "Local stack (make up):"
  check_docker
  port_free 3000 "The storefront"
}

check_kind() {
  echo "Local Kubernetes (make kind-up):"
  check_docker
  need kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation  (or use the dev container)"
  need kubectl "https://kubernetes.io/docs/tasks/tools/"
  need helm "https://helm.sh/docs/intro/install/"
  port_free 8080 "The kind storefront"
}

check_azure() {
  echo "Azure (see README, Deploy to Azure):"
  need az "https://learn.microsoft.com/cli/azure/install-azure-cli"
  need jq "https://jqlang.org/download/"
  need kubelogin "az aks install-cli  (signs kubectl in through Entra ID; the cluster has no local accounts)"
  need kubectl "https://kubernetes.io/docs/tasks/tools/"
  need helm "https://helm.sh/docs/intro/install/"
  if command -v terraform >/dev/null 2>&1; then
    v=$(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null)
    if [ -n "$v" ] && version_ge "$v" 1.15.0; then ok "terraform $v"; else bad "terraform ${v:-unknown} is older than 1.15" "https://developer.hashicorp.com/terraform/install"; fi
  else
    bad "terraform not found" "https://developer.hashicorp.com/terraform/install"
  fi
  if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then ok "az logged in"; else warn "not logged in to Azure" "Run 'az login'."; fi
  if [ -f infra/azure/envs/dev/backend.hcl ]; then ok "backend.hcl present"; else warn "infra/azure/envs/dev/backend.hcl missing" "Run scripts/bootstrap-tfstate.sh once."; fi
}

case "$TARGET" in
  local) check_local ;;
  kind)  check_kind ;;
  azure) check_azure ;;
  all)   check_local; check_kind; check_azure ;;
  *) echo "usage: $0 [local|kind|azure|all]" >&2; exit 2 ;;
esac

if [ "$failed" -ne 0 ]; then echo "Some requirements are missing."; exit 1; fi
echo "All good."
