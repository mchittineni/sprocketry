.PHONY: help doctor up up-prebuilt rebuild down logs smoke e2e fault grafana slo slo-test test test-docker kind-up canary-demo chaos kind-down azure-destroy tf-validate helm-lint
.DEFAULT_GOAL := help

TF_DIR := infra/azure/envs/dev
K6_IMAGE := grafana/k6:2.3.0
SLOTH_IMAGE := ghcr.io/slok/sloth:v0.16.0
PROMTOOL_IMAGE := prom/prometheus:v3.15.0
SLO_RULES := deploy/helm/sprocketry/files/prometheus/rules

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

doctor: ## Check prerequisites (doctor TARGET=kind|azure|aws|gcp|all for the other paths)
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
	@# The other sidecars cache the old sidecar's address and would keep calling it; restart them to re-resolve.
	docker compose restart $$(docker compose config --services | grep -- '-dapr$$' | grep -vx '$(SVC)-dapr')

down: ## Stop the local stack and delete its data
	docker compose down -v

logs: ## Follow logs from every container
	docker compose logs -f --tail=50

smoke: ## Load test the storefront (BASE_URL=... for another target); uses k6, or its container
	@if command -v k6 >/dev/null 2>&1; then k6 run loadgen/smoke.js; \
	else docker run --rm -i --add-host=host.docker.internal:host-gateway \
	  -e BASE_URL="$$(echo "$${BASE_URL:-http://localhost:3000}" | sed 's#//localhost#//host.docker.internal#')" \
	  -e VUS -e DURATION $(K6_IMAGE) run - < loadgen/smoke.js; fi

GOLANGCI_LINT_IMAGE := golangci/golangci-lint:v2.15.0
TEST_PG := sprocketry-test-pg
TEST_NET := sprocketry-test

e2e: ## End-to-end checks through the real Dapr sidecars against the running local stack
	./scripts/e2e.sh

fault: ## Toggle a fault flag at runtime: make fault FLAG=payment-failure-rate VARIANT=20pct (no args lists them)
	./scripts/fault.sh $(if $(FLAG),$(FLAG) $(VARIANT))

test: ## Lint and test every service (needs Go, golangci-lint, .NET, Node and Python; see test-docker)
	cd services/catalog && test -z "$$(gofmt -l .)" && golangci-lint run ./... && go test -race ./...
	cd services/fulfillment && test -z "$$(gofmt -l .)" && golangci-lint run ./... && go test -race ./...
	cd services/cart && dotnet build -c Release -warnaserror && dotnet format Cart.csproj --verify-no-changes
	cd services/cart/tests && dotnet test -c Release
	cd services/shipping && npm ci && npm run lint && npm run build && npm test
	cd services/storefront && npm ci && npm run lint && npm run build && npm test
	cd services/payment && pip install -q ".[dev]" && ruff check . && ruff format --check . && pytest -q
	cd services/reviews && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked
	cd services/profile && mvn -B -q verify
	@echo "Database tests (catalog, reviews, profile) skip unless TEST_DATABASE_URL is set; test-docker provides one."

# Runs a command in a toolchain container with services/<name> mounted, as the current user.
# The optional fourth argument adds docker run flags.
in_container = docker run --rm $(4) -u $$(id -u):$$(id -g) -e HOME=/tmp -v $(CURDIR)/services/$(1):/src -w /src $(2) sh -c '$(3)'

go_checks := test -z "$$(gofmt -l .)" && go vet ./... && go test -race ./...

# Runs a service's checks in a toolchain container beside a throwaway PostgreSQL database named after it.
with_test_db = docker rm -f $(TEST_PG) >/dev/null 2>&1; docker network create $(TEST_NET) >/dev/null 2>&1; \
	docker run -d --name $(TEST_PG) --network $(TEST_NET) -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=$(1) postgres:18-alpine >/dev/null && \
	until docker exec $(TEST_PG) pg_isready -h 127.0.0.1 -U test >/dev/null 2>&1; do sleep 1; done && \
	$(call in_container,$(1),$(2),$(3),--network $(TEST_NET) -e TEST_DATABASE_URL=postgres://test:test@$(TEST_PG):5432/$(1)); \
	status=$$?; docker rm -f $(TEST_PG) >/dev/null; exit $$status

test-docker: ## Lint and test every service, using only Docker
	@docker network create $(TEST_NET) >/dev/null 2>&1 || true
	@docker rm -f $(TEST_PG) >/dev/null 2>&1 || true
	docker run -d --name $(TEST_PG) --network $(TEST_NET) -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=catalog postgres:18-alpine >/dev/null
	@until docker exec $(TEST_PG) pg_isready -h 127.0.0.1 -U test >/dev/null 2>&1; do sleep 1; done
	$(call in_container,catalog,golang:1.27,$(go_checks),--network $(TEST_NET) -e TEST_DATABASE_URL=postgres://test:test@$(TEST_PG):5432/catalog) \
	  ; status=$$?; docker rm -f $(TEST_PG) >/dev/null; exit $$status
	$(call in_container,catalog,$(GOLANGCI_LINT_IMAGE),golangci-lint run ./...)
	$(call in_container,fulfillment,golang:1.27,$(go_checks))
	$(call in_container,fulfillment,$(GOLANGCI_LINT_IMAGE),golangci-lint run ./...)
	$(call in_container,cart,mcr.microsoft.com/dotnet/sdk:10.0,dotnet build -c Release -warnaserror && dotnet format Cart.csproj --verify-no-changes && cd tests && dotnet test -c Release)
	$(call in_container,shipping,node:24-alpine,npm ci && npm run lint && npm run build && npm test)
	$(call in_container,storefront,node:24-alpine,npm ci && npm run lint && npm run build && npm test)
	$(call in_container,payment,python:3.14-slim,python -m venv /tmp/venv && /tmp/venv/bin/pip install -q ".[dev]" && /tmp/venv/bin/ruff check . && /tmp/venv/bin/ruff format --check . && /tmp/venv/bin/pytest -q -p no:cacheprovider,-v $(CURDIR)/deploy/helm/sprocketry/files/flagd:/flags:ro -e FLAGS_FILE=/flags/faults.json)
	$(call with_test_db,reviews,rust:1.99-slim-trixie,CARGO_HOME=/tmp/cargo cargo fmt --check && CARGO_HOME=/tmp/cargo cargo clippy --all-targets --locked -- -D warnings && CARGO_HOME=/tmp/cargo cargo test --locked)
	$(call with_test_db,profile,maven:3.9.16-eclipse-temurin-25,mvn -B -q -Dmaven.repo.local=/tmp/m2 verify)

# ---------- SLOs ----------
slo: ## Generate the Prometheus SLO rules from deploy/slo/specs (then restart lgtm to load them)
	rm -f $(SLO_RULES)/*.yaml
	docker run --rm -u $$(id -u):$$(id -g) -v $(CURDIR):/repo -w /repo $(SLOTH_IMAGE) \
	  generate --no-log -i deploy/slo/specs -o $(SLO_RULES)

slo-test: slo ## Regenerate the SLO rules, validate them and run the burn-rate alert tests
	docker run --rm -v $(CURDIR)/deploy:/deploy:ro -w /deploy/slo --entrypoint sh $(PROMTOOL_IMAGE) -c '\
	  promtool check config --syntax-only /deploy/helm/sprocketry/files/prometheus/prometheus.yaml && \
	  promtool check rules /deploy/helm/sprocketry/files/prometheus/rules/*.yaml && \
	  promtool test rules tests/*.yaml'

# ---------- Local Kubernetes (kind) ----------
kind-up: ## Run the app on a local kind cluster (storefront on http://localhost:8080)
	./scripts/kind-up.sh

canary-demo: ## Release a faulty payment to the kind cluster and watch Argo Rollouts roll it back, then a good one
	./scripts/canary-demo.sh

chaos: ## Run a chaos experiment on the kind cluster: make chaos EXPERIMENT=cart-pod-kill (no args lists them)
	./scripts/chaos.sh $(EXPERIMENT)

kind-down: ## Delete the kind cluster
	kind delete cluster --name $(or $(CLUSTER),sprocketry)

grafana: ## Open Grafana from the cluster in the current kube context on http://localhost:3001 (admin/admin)
	kubectl -n sprocketry port-forward svc/lgtm 3001:3000

# ---------- Azure ----------
azure-destroy: ## Delete every Azure resource Terraform created (state storage is kept)
	terraform -chdir=$(TF_DIR) destroy
	@echo "To also remove Terraform state: az group delete -n rg-terraform-state"

tf-validate: ## Format-check, validate and plan-test every cloud's Terraform offline (no cloud login needed)
	terraform fmt -check -recursive infra
	@for cloud in azure aws gcp; do \
	  echo "==> $$cloud"; \
	  terraform -chdir=infra/$$cloud/envs/dev init -backend=false -input=false >/dev/null && \
	  terraform -chdir=infra/$$cloud/envs/dev validate && \
	  terraform -chdir=infra/$$cloud/envs/dev test || exit 1; \
	done

helm-lint: ## Lint the chart with the Azure and local values
	helm lint deploy/helm/sprocketry -f deploy/helm/sprocketry/values-azure.example.yaml
	helm lint deploy/helm/sprocketry -f deploy/helm/sprocketry/values-local.yaml
