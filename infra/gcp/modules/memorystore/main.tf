# ==================== Memorystore for Redis ====================
# Memorystore for Redis, not Memorystore for Valkey. Dapr's state.redis component authenticates with
# a static password (or Entra ID on Azure); it cannot mint Google IAM tokens, so Valkey would have to
# run with authentication off. Valkey also needs Private Service Connect and is cluster-mode first.
# Redis gives AUTH plus TLS over the Private Service Access peering the network module already sets up.
#
# TLS: Memorystore signs its server certificate with a per-instance CA that no public trust store
# contains, and Dapr's Redis component (components-contrib release-1.18,
# common/component/redis/settings.go) has no CA option: only enableTLS, insecureSkipTLSVerify and a
# client certificate. Its TLS config leaves RootCAs empty, so Go falls back to the system roots, which
# Go extends with every file in $SSL_CERT_DIR. The chart can therefore get a fully verified connection
# by mounting server_ca_certs (output `redis_ca_certificate`) into the daprd sidecar and setting
# SSL_CERT_DIR (dapr.io/volume-mounts + dapr.io/env). Go checks the certificate against the IP Dapr
# dials; confirm once with `openssl s_client` that the certificate lists it. The fallback is insecureSkipTLSVerify: still
# encrypted and AUTH-protected, but not protected against an impersonated server inside the VPC.
# Plain text is not an option once TLS is on: Memorystore rejects non-TLS clients.
resource "google_redis_instance" "this" {
  name           = var.name
  region         = var.region
  tier           = var.tier
  memory_size_gb = var.memory_size_gb
  redis_version  = var.redis_version

  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = var.network_id
  reserved_ip_range  = var.reserved_ip_range

  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  # Carts and sign-in sessions are short-lived; losing them on a restart is acceptable in dev.
  persistence_config {
    persistence_mode = "DISABLED"
  }

  # dev is meant to be torn down; enable for long-lived environments.
  deletion_protection = false
}
