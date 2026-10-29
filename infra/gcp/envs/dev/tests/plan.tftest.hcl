# Offline plan tests: google is mocked, so these need no GCP credentials and create nothing.
# Run with `terraform test`. They prove the configuration plans with the pinned provider and that the
# security settings hold. Real API behaviour still needs a real plan.

mock_provider "google" {
  # Data sources are read during plan; principals are built from the project number.
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_client_openid_userinfo" {
    defaults = {
      email = "caller@example.com"
    }
  }
}

mock_provider "random" {}

variables {
  project_id = "sprocketry-test"
  owner      = "Tests@Example.com"
}

# ---------- Whole environment ----------

run "environment_plans_with_explicit_deployers" {
  command = plan

  variables {
    deployer_members = ["user:a@example.com", "serviceAccount:ci@sprocketry-test.iam.gserviceaccount.com"]
  }

  assert {
    condition     = local.deployers == toset(["user:a@example.com", "serviceAccount:ci@sprocketry-test.iam.gserviceaccount.com"])
    error_message = "Explicit deployers should be used as given."
  }

  assert {
    condition     = local.labels.owner == "tests_example_com"
    error_message = "The owner label should be lower-cased with disallowed characters replaced."
  }

  assert {
    condition = output.secret_ids == sort([
      "catalog-database-url", "shipping-database-url", "redis-host", "redis-password",
      "reviews-database-url", "profile-database-url", "keycloak-db-url", "keycloak-db-username",
      "keycloak-db-password", "keycloak-admin-password", "storefront-client-secret",
    ])
    error_message = "Secret Manager must hold exactly the 11 secret IDs the chart's ExternalSecret maps."
  }

  assert {
    condition     = output.artifact_registry == "europe-west2-docker.pkg.dev/sprocketry-test/sprocketry"
    error_message = "Artifact Registry path should be <region>-docker.pkg.dev/<project>/sprocketry."
  }

  assert {
    condition     = output.pubsub_topic == "orders" && output.pubsub_subscription == "fulfillment-orders"
    error_message = "Pub/Sub entities must be named as Dapr expects: topic orders, subscription <consumerID>-<topic>."
  }

  assert {
    condition = (
      google_pubsub_topic_iam_member.payment_publisher.role == "roles/pubsub.publisher" &&
      google_pubsub_topic_iam_member.payment_publisher.topic == "orders" &&
      google_pubsub_topic_iam_member.payment_publisher.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sprocketry-test.svc.id.goog/subject/ns/sprocketry/sa/payment"
    )
    error_message = "Only payment's service account should publish, and only to the orders topic."
  }

  assert {
    condition = (
      google_pubsub_subscription_iam_member.fulfillment_subscriber.role == "roles/pubsub.subscriber" &&
      google_pubsub_subscription_iam_member.fulfillment_subscriber.subscription == "fulfillment-orders" &&
      google_pubsub_subscription_iam_member.fulfillment_subscriber.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sprocketry-test.svc.id.goog/subject/ns/sprocketry/sa/fulfillment"
    )
    error_message = "Only fulfillment's service account should consume, and only the fulfillment-orders subscription."
  }

  assert {
    condition = output.workload_identity_principals["external-secrets"] == {
      external-secrets = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sprocketry-test.svc.id.goog/subject/ns/external-secrets/sa/external-secrets"
    }
    error_message = "External Secrets should act as external-secrets/external-secrets only."
  }
}

run "environment_plans_with_user_caller_fallback" {
  command = plan

  variables {
    deployer_members = []
  }

  assert {
    condition     = local.deployers == toset(["user:caller@example.com"])
    error_message = "With no deployers, the caller should become the only cluster admin."
  }
}

run "environment_plans_with_service_account_caller_fallback" {
  command = plan

  variables {
    deployer_members = []
  }

  override_data {
    target = data.google_client_openid_userinfo.current
    values = {
      email = "ci@sprocketry-test.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = local.deployers == toset(["serviceAccount:ci@sprocketry-test.iam.gserviceaccount.com"])
    error_message = "A service account caller should be granted as serviceAccount:, not user:."
  }
}

run "deployers_must_be_iam_members" {
  command = plan

  variables {
    deployer_members = ["a@example.com"]
  }

  expect_failures = [var.deployer_members]
}

# ---------- Modules ----------

run "gke_is_private_with_workload_identity" {
  command = plan

  module {
    source = "../../modules/gke"
  }

  variables {
    name                = "gke-test"
    project_id          = "sprocketry-test"
    region              = "europe-west2"
    location            = "europe-west2-a"
    network_id          = "projects/sprocketry-test/global/networks/test-vpc"
    subnetwork_id       = "projects/sprocketry-test/regions/europe-west2/subnetworks/test-gke"
    pods_range_name     = "pods"
    services_range_name = "services"
    admin_members       = ["user:a@example.com", "group:ops@example.com"]
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_nodes
    error_message = "Nodes must have private IPs only."
  }

  assert {
    condition     = google_container_cluster.this.workload_identity_config[0].workload_pool == "sprocketry-test.svc.id.goog"
    error_message = "Workload Identity Federation for GKE must be enabled with the project's pool."
  }

  assert {
    condition     = google_container_node_pool.default.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "Pods must use the GKE metadata server, never the node's credentials."
  }

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "The cluster should use Dataplane V2."
  }

  assert {
    condition     = !google_container_cluster.this.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled
    error_message = "The IP endpoint must not be open to all of Google Cloud's public ranges."
  }

  assert {
    condition     = length(google_project_iam_member.cluster_admin) == 2
    error_message = "Each deployer should get Kubernetes admin."
  }

  assert {
    condition     = one(google_compute_firewall.control_plane_to_dapr_webhooks.allow).ports == tolist(["4000", "19443"])
    error_message = "Only Dapr's webhook ports should be opened to the control plane."
  }
}

run "cloudsql_is_private_and_requires_ssl" {
  command = plan

  module {
    source = "../../modules/cloudsql"
  }

  variables {
    name               = "sql-test"
    region             = "europe-west2"
    network_id         = "projects/sprocketry-test/global/networks/test-vpc"
    allocated_ip_range = "test-private-services"
    databases          = ["catalog", "shipping", "reviews", "profile", "keycloak"]
  }

  assert {
    condition     = !google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled
    error_message = "Cloud SQL must have no public IP."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "Cloud SQL must refuse unencrypted connections."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled
    error_message = "Backups must be on."
  }

  assert {
    condition     = google_sql_database_instance.this.database_version == "POSTGRES_18"
    error_message = "Cloud SQL should run PostgreSQL 18."
  }

  assert {
    condition     = length(google_sql_database.this) == 5
    error_message = "Each service that owns data should get a database."
  }
}

run "memorystore_requires_auth_and_tls" {
  command = plan

  module {
    source = "../../modules/memorystore"
  }

  variables {
    name              = "redis-test"
    region            = "europe-west2"
    network_id        = "projects/sprocketry-test/global/networks/test-vpc"
    reserved_ip_range = "test-private-services"
  }

  assert {
    condition     = google_redis_instance.this.auth_enabled
    error_message = "Memorystore must require AUTH."
  }

  assert {
    condition     = google_redis_instance.this.transit_encryption_mode == "SERVER_AUTHENTICATION"
    error_message = "Memorystore must encrypt traffic in transit."
  }

  assert {
    condition     = google_redis_instance.this.connect_mode == "PRIVATE_SERVICE_ACCESS"
    error_message = "Memorystore must be reachable over Private Service Access only."
  }
}

run "secrets_are_readable_only_by_accessors" {
  command = plan

  module {
    source = "../../modules/secrets"
  }

  variables {
    accessor_members = ["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sprocketry-test.svc.id.goog/subject/ns/external-secrets/sa/external-secrets"]
    secrets = {
      "catalog-database-url" = "postgres://example"
      "redis-password"       = "example"
    }
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.accessor) == 2
    error_message = "The accessor should be bound on each secret, individually."
  }

  assert {
    condition     = alltrue([for b in google_secret_manager_secret_iam_member.accessor : b.role == "roles/secretmanager.secretAccessor"])
    error_message = "Accessors should only be able to read secret payloads."
  }

  assert {
    condition     = alltrue([for b in google_secret_manager_secret_iam_member.accessor : b.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sprocketry-test.svc.id.goog/subject/ns/external-secrets/sa/external-secrets"])
    error_message = "Only the External Secrets principal should be granted access."
  }

  assert {
    condition     = length(google_secret_manager_secret_version.this) == 2
    error_message = "Every secret passed in should get a version."
  }
}

run "pubsub_subscription_never_expires" {
  command = plan

  module {
    source = "../../modules/pubsub"
  }

  variables {
    topics = { orders = ["fulfillment"] }
  }

  assert {
    condition     = google_pubsub_subscription.this["orders/fulfillment"].name == "fulfillment-orders"
    error_message = "Subscription must be named <consumerID>-<topic>, as Dapr expects."
  }

  assert {
    condition     = google_pubsub_subscription.this["orders/fulfillment"].expiration_policy[0].ttl == ""
    error_message = "The subscription must not expire when idle."
  }
}
