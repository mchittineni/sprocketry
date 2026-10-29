output "private_ip" {
  value = google_sql_database_instance.this.private_ip_address
}

output "connection_name" {
  value = google_sql_database_instance.this.connection_name
}

# Connection string per database, consumed by Secret Manager.
output "connection_strings" {
  value = {
    for db in var.databases :
    db => "postgres://${var.user_name}:${random_password.app.result}@${google_sql_database_instance.this.private_ip_address}:5432/${db}?sslmode=require"
  }
  sensitive = true
}

# JDBC form of each database's address, for Java services such as Keycloak. Credentials are separate.
output "jdbc_urls" {
  value = {
    for db in var.databases :
    db => "jdbc:postgresql://${google_sql_database_instance.this.private_ip_address}:5432/${db}?sslmode=require"
  }
}

output "user_name" {
  value = google_sql_user.app.name
}

output "user_password" {
  value     = random_password.app.result
  sensitive = true
}
