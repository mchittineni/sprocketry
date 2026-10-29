output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

# Image registry for the chart: <artifact_registry>/<service>:<tag>.
output "artifact_registry" {
  value = module.gke.artifact_registry
}

# Feed these into deploy/helm/sprocketry/values-gcp.yaml (Dapr pubsub component).
output "pubsub_topic" {
  value = module.pubsub.topic_names["orders"]
}

output "pubsub_subscription" {
  value = module.pubsub.subscription_names["orders/fulfillment"]
}

# PEM the daprd sidecar trusts to verify Memorystore's TLS certificate. Public, not a secret.
output "redis_ca_certificate" {
  value = module.memorystore.ca_certificates
}

output "secret_ids" {
  value = module.secrets.secret_ids
}

# The IAM principals the Kubernetes service accounts act as, for reference and debugging.
output "workload_identity_principals" {
  value = module.workload_identity.principals
}
