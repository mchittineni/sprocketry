# ==================== Node Service Account ====================
# Nodes get their own minimal identity instead of the Compute Engine default (Editor on the project).
# Pods never use it: Workload Identity Federation gives each Kubernetes service account its own principal.
resource "google_service_account" "nodes" {
  account_id   = "${var.name}-nodes"
  display_name = "GKE nodes for ${var.name}"
}

resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount" # logging, monitoring and metadata writers only
  member  = google_service_account.nodes.member
}

# ==================== GKE Cluster ====================
# GKE Standard, not Autopilot: Dapr's sidecar injector, Chaos Mesh (privileged chaos-daemon, host
# PID/network faults) and Argo Rollouts need node-level access and admission webhooks that Autopilot
# restricts. Zonal, because a regional cluster triples the node count and one zonal cluster's
# management fee is covered by the GKE free tier.
resource "google_container_cluster" "this" {
  name     = var.name
  location = var.location

  network    = var.network_id
  subnetwork = var.subnetwork_id

  # Node pools are managed separately, so the default one is removed right after creation. Provider
  # 8.9 deprecates this in favour of initial_node_count = 0, which only works from GKE
  # 1.36.4-gke.1469000; switch once the release channel's default version is past that.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.release_channel
  }

  # Dataplane V2 (eBPF/Cilium) enforces NetworkPolicy natively, like Azure's Cilium dataplane.
  datapath_provider = "ADVANCED_DATAPATH"
  networking_mode   = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity Federation for GKE: pods exchange their Kubernetes token for a Google token, so
  # there are no key files. IAM bindings target the Kubernetes service account directly.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Nodes have private IPs only. The fixed control plane range lets the firewall rule below open
  # Dapr's webhook ports to it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  # People and CI reach the API server through the DNS endpoint, which is authorised by IAM
  # (`gcloud container clusters get-credentials --dns-endpoint`). The IP endpoint stays for the
  # nodes and is closed to the internet unless CIDRs are listed.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = cidr_blocks.value
      }
    }
  }

  # No client certificates or basic auth: sign-in is Google IAM only.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  enable_shielded_nodes = true

  # dev is meant to be torn down; enable for long-lived environments.
  deletion_protection = false
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.id
  location = var.location

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.node_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    # Access is governed by IAM on the service account, not by legacy scopes.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    tags         = [local.node_tag]

    # Pods see the GKE metadata server (Workload Identity), never the node's own credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# GKE's own firewall rule only lets the control plane reach nodes on 443 and 10250. Dapr's sidecar
# injector listens on 4000 and its CRD conversion webhook on 19443
# (https://docs.dapr.io/operations/hosting/kubernetes/cluster/setup-gke/). Without this, pods start
# without sidecars. Chaos Mesh and External Secrets webhooks already use 10250.
resource "google_compute_firewall" "control_plane_to_dapr_webhooks" {
  name          = "${var.name}-cp-to-dapr-webhooks"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = [var.master_ipv4_cidr]
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["4000", "19443"]
  }
}

# Deployers (people and CI) administer the cluster. GKE has no per-cluster IAM, so this is project
# scoped; Kubernetes RBAC maps roles/container.admin to cluster-admin.
resource "google_project_iam_member" "cluster_admin" {
  for_each = var.admin_members
  project  = var.project_id
  role     = "roles/container.admin"
  member   = each.value
}

# ==================== Artifact Registry ====================
# One Docker repository; each service is an image in it (<registry>/storefront, <registry>/cart, ...).
# Tags stay mutable because the chart falls back to the `latest` tag.
resource "google_artifact_registry_repository" "this" {
  repository_id = var.repository_id
  location      = var.region
  format        = "DOCKER"
  description   = "Sprocketry service images"

  # CI pushes a tag per commit; untagged layers from overwritten tags are cleaned up.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.nodes.member
}

locals {
  node_tag = "${var.name}-node"
}
