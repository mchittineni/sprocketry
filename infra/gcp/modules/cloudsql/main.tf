# ==================== Cloud SQL for PostgreSQL ====================
resource "random_password" "app" {
  length  = 32
  special = false # keeps the password URL-safe for connection strings
}

resource "google_sql_database_instance" "this" {
  name             = var.name
  region           = var.region
  database_version = var.database_version

  settings {
    # Enterprise, not Enterprise Plus (the default for new PostgreSQL 16+ instances), so the small
    # dev tiers are available.
    edition           = "ENTERPRISE"
    tier              = var.tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true

    # Private IP only, over Private Service Access. SSL is required on every connection; the services
    # use sslmode=require, so client certificates are not demanded.
    ip_configuration {
      ipv4_enabled       = false
      private_network    = var.network_id
      allocated_ip_range = var.allocated_ip_range
      ssl_mode           = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "02:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
      }
    }

    # Connection and lock logging, which security scanners expect and are cheap at dev volumes.
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }

    deletion_protection_enabled = false
  }

  # dev is meant to be torn down; enable both protections for long-lived environments.
  deletion_protection = false
}

# One database per service that owns data.
resource "google_sql_database" "this" {
  for_each = toset(var.databases)
  name     = each.key
  instance = google_sql_database_instance.this.name
  # PostgreSQL refuses to drop databases or roles that still own objects. Deleting the instance
  # removes them anyway, so Terraform just forgets them on destroy.
  deletion_policy = "ABANDON"
}

# A built-in (password) user shared by the services, like the Azure server's admin login. Give each
# service its own role (e.g. with the postgresql provider) for anything beyond a dev environment.
resource "google_sql_user" "app" {
  name            = var.user_name
  instance        = google_sql_database_instance.this.name
  type            = "BUILT_IN"
  password        = random_password.app.result
  deletion_policy = "ABANDON"
}
