# host:port. With TLS on, the port is 6378.
output "host" {
  value = "${google_redis_instance.this.host}:${google_redis_instance.this.port}"
}

output "auth_string" {
  value     = google_redis_instance.this.auth_string
  sensitive = true
}

# PEM of the per-instance CA(s). Public, but needed by clients to verify the server.
output "ca_certificates" {
  value = join("\n", google_redis_instance.this.server_ca_certs[*].cert)
}
