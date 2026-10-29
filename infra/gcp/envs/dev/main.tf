# ==================== Locals ====================
locals {
  name = "${var.project}-${var.environment}"

  labels = {
    project     = var.project
    environment = var.environment
    owner       = replace(lower(var.owner), "/[^a-z0-9_-]/", "_")
    managed-by  = "terraform"
  }

  app_namespace = "sprocketry"

  # A fixed list, so a plan run by CI and an apply run by you agree on the same IAM bindings. The
  # fallback uses the caller's email; service account emails end in gserviceaccount.com.
  caller    = data.google_client_openid_userinfo.current.email
  deployer  = endswith(local.caller, "gserviceaccount.com") ? "serviceAccount:${local.caller}" : "user:${local.caller}"
  deployers = toset(length(var.deployer_members) > 0 ? var.deployer_members : [local.deployer])
}

data "google_project" "this" {
  project_id = var.project_id
}

data "google_client_openid_userinfo" "current" {}

# Cloud SQL names can't be reused for a week after deletion, so the instance gets a random suffix.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# ==================== Project APIs ====================
# Left enabled on destroy: other things in the project may use them.
resource "google_project_service" "this" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "pubsub.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ==================== Network ====================
module "network" {
  source = "../../modules/network"
  name   = local.name
  region = var.region

  depends_on = [google_project_service.this]
}

# ==================== Compute ====================
module "gke" {
  source                  = "../../modules/gke"
  name                    = "gke-${local.name}"
  project_id              = var.project_id
  region                  = var.region
  location                = var.zone
  network_id              = module.network.network_id
  subnetwork_id           = module.network.subnetwork_id
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  master_authorized_cidrs = var.master_authorized_cidrs
  release_channel         = var.release_channel
  node_machine_type       = var.node_machine_type
  node_max_count          = var.node_max_count
  admin_members           = local.deployers
  repository_id           = var.project

  depends_on = [google_project_service.this]
}

# ==================== Data ====================
module "cloudsql" {
  source             = "../../modules/cloudsql"
  name               = "sql-${local.name}-${random_string.suffix.result}"
  region             = var.region
  network_id         = module.network.network_id
  allocated_ip_range = module.network.private_services_range_name
  databases          = ["catalog", "shipping", "reviews", "profile", "keycloak"]

  # A private-IP instance can only be created once the Private Service Access peering exists.
  depends_on = [module.network, google_project_service.this]
}

module "memorystore" {
  source            = "../../modules/memorystore"
  name              = "redis-${local.name}"
  region            = var.region
  network_id        = module.network.network_id
  reserved_ip_range = module.network.private_services_range_name

  depends_on = [module.network, google_project_service.this]
}

# ==================== Messaging ====================
module "pubsub" {
  source = "../../modules/pubsub"
  topics = { orders = ["fulfillment"] }

  depends_on = [google_project_service.this]
}

# ==================== Secrets ====================
# Keycloak's bootstrap admin, and the secret the storefront signs in to Keycloak with.
resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}

resource "random_password" "storefront_client" {
  length  = 48
  special = false
}

# Secret Manager is the single source of truth. External Secrets Operator syncs these into Kubernetes.
module "secrets" {
  source           = "../../modules/secrets"
  accessor_members = values(module.workload_identity.principals["external-secrets"])

  secrets = {
    "catalog-database-url"  = module.cloudsql.connection_strings["catalog"]
    "shipping-database-url" = module.cloudsql.connection_strings["shipping"]
    "redis-host"            = module.memorystore.host
    "redis-password"        = module.memorystore.auth_string
    "reviews-database-url"  = module.cloudsql.connection_strings["reviews"]
    "profile-database-url"  = module.cloudsql.connection_strings["profile"]
    # Keycloak shares the services' database user: the google provider can't grant PostgreSQL
    # privileges. Give it its own role (e.g. with the postgresql provider) beyond a dev environment.
    "keycloak-db-url"          = module.cloudsql.jdbc_urls["keycloak"]
    "keycloak-db-username"     = module.cloudsql.user_name
    "keycloak-db-password"     = module.cloudsql.user_password
    "keycloak-admin-password"  = random_password.keycloak_admin.result
    "storefront-client-secret" = random_password.storefront_client.result
  }

  depends_on = [google_project_service.this]
}

# ==================== Workload Identity ====================
module "workload_identity" {
  source         = "../../modules/workload-identity"
  project_id     = var.project_id
  project_number = data.google_project.this.number

  identities = {
    # Used by the Dapr sidecars of the services that publish or consume events.
    apps = {
      namespace        = local.app_namespace
      service_accounts = ["payment", "fulfillment"]
    }
    # Used by External Secrets Operator to read Secret Manager.
    external-secrets = {
      namespace        = "external-secrets"
      service_accounts = ["external-secrets"]
    }
  }
}

# Each service gets only the half of the topic it uses: payment publishes, fulfillment consumes.
# Granted on the topic and subscription themselves, not the project.
resource "google_pubsub_topic_iam_member" "payment_publisher" {
  topic  = module.pubsub.topic_names["orders"]
  role   = "roles/pubsub.publisher"
  member = module.workload_identity.principals["apps"]["payment"]
}

resource "google_pubsub_subscription_iam_member" "fulfillment_subscriber" {
  subscription = module.pubsub.subscription_names["orders/fulfillment"]
  role         = "roles/pubsub.subscriber"
  member       = module.workload_identity.principals["apps"]["fulfillment"]
}
