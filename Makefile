.PHONY: help doctor up up-prebuilt rebuild down logs smoke test test-docker kind-up kind-down azure-destroy tf-validate helm-lint
.DEFAULT_GOAL := help

TF_DIR := infra/azure/envs/dev
K6_IMAGE := grafana/k6:2.3.0

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

doctor: ## Check prerequisites (doctor TARGET=kind|azure|all for the other paths)
	@./scripts/doctor.sh $(or $(TARGET),local)

# ---------- Local stack (Docker only) ----------
up: ## Build and start the local stack (storefront on http://localhost:3000)
	docker compose up --build -d

up-prebuilt: ## Start the local stack from published images, without building
	docker compose up -d --no-build --pull always

rebuild: ## Rebuild one service and its Dapr sidecar, e.g. make rebuild SVC=storefront
	@test -n "$(SVC)" || { echo "usage: make rebuild SVC=<service>"; exit 2; }
	docker compose up --build -d $(SVC)
	docker compose up -d --force-recreate $(SVC)-dapr

down: ## Stop the local stack and delete its data
	docker compose down -v

logs: ## Follow logs from every container
	docker compose logs -f --tail=50

smoke: ## Load test the storefront (BASE_URL=... for another target); uses k6, or its container
	@if command -v k6 >/dev/null 2>&1; then k6 run loadgen/smoke.js; \
	else docker run --rm -i --add-host=host.docker.internal:host-gateway \
	  -e BASE_URL="$$(echo "$${BASE_URL:-http://localhost:3000}" | sed 's#//localhost#//host.docker.internal#')" \
	  -e VUS -e DURATION $(K6_IMAGE) run - < loadgen/smoke.js; fi

test: ## Unit tests for every service (needs Go, .NET, Node and Python; see test-docker)
	cd services/catalog && go vet ./... && go test ./...
	cd services/fulfillment && go vet ./... && go test ./...
	cd services/cart && dotnet build -c Release -warnaserror
	cd services/shipping && npm ci && npm run build && npm test
	cd services/storefront && npm ci && npm run build
	cd services/payment && pip install -q ".[dev]" && pytest -q

# Runs a command in a toolchain container with services/<name> mounted, as the current user.
in_container = docker run --rm -u $$(id -u):$$(id -g) -e HOME=/tmp -v $(CURDIR)/services/$(1):/src -w /src $(2) sh -c '$(3)'

test-docker: ## Unit tests for every service, using only Docker
	$(call in_container,catalog,golang:1.27,go vet ./... && go test ./...)
	$(call in_container,fulfillment,golang:1.27,go vet ./... && go test ./...)
	$(call in_container,cart,mcr.microsoft.com/dotnet/sdk:10.0,dotnet build -c Release -warnaserror)
	$(call in_container,shipping,node:24-alpine,npm ci && npm run build && npm test)
	$(call in_container,storefront,node:24-alpine,npm ci && npm run build)
	$(call in_container,payment,python:3.14-slim,python -m venv /tmp/venv && /tmp/venv/bin/pip install -q ".[dev]" && /tmp/venv/bin/pytest -q -p no:cacheprovider)

# ---------- Local Kubernetes (kind) ----------
kind-up: ## Run the app on a local kind cluster (storefront on http://localhost:8080)
	./scripts/kind-up.sh

kind-down: ## Delete the kind cluster
	kind delete cluster --name $(or $(CLUSTER),sprocketry)

# ---------- Azure ----------
azure-destroy: ## Delete every Azure resource Terraform created (state storage is kept)
	terraform -chdir=$(TF_DIR) destroy
	@echo "To also remove Terraform state: az group delete -n rg-terraform-state"

tf-validate: ## Format-check, validate and plan-test Terraform offline (no Azure login needed)
	terraform fmt -check -recursive infra
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate
	terraform -chdir=$(TF_DIR) test

helm-lint: ## Lint the chart with the Azure and local values
	helm lint deploy/helm/sprocketry -f deploy/helm/sprocketry/values-azure.example.yaml
	helm lint deploy/helm/sprocketry -f deploy/helm/sprocketry/values-local.yaml
