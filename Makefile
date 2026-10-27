.PHONY: up down logs smoke test tf-validate helm-lint

up: ## Build and start the local stack (storefront on http://localhost:3000)
	docker compose up --build -d

down:
	docker compose down -v

logs:
	docker compose logs -f --tail=50

smoke: ## Requires k6
	k6 run loadgen/smoke.js

test: ## Unit tests for every service
	cd services/catalog && go vet ./...
	cd services/fulfillment && go vet ./...
	cd services/cart && dotnet build -c Release -warnaserror
	cd services/shipping && npm ci && npm run build && npm test
	cd services/storefront && npm ci && npm run build
	cd services/payment && pip install -q ".[dev]" && pytest -q

tf-validate:
	terraform fmt -check -recursive infra
	terraform -chdir=infra/azure/envs/dev init -backend=false -input=false
	terraform -chdir=infra/azure/envs/dev validate

helm-lint:
	helm lint deploy/helm/sprocketry -f deploy/helm/sprocketry/values-azure.example.yaml
