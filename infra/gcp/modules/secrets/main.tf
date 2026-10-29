# ==================== Secret Manager ====================
locals {
  # Keys are not secret; only values are. for_each cannot iterate a sensitive map directly.
  secret_ids = nonsensitive(toset(keys(var.secrets)))
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.secret_ids
  secret_id = each.key

  replication {
    auto {}
  }
}

# Values are written with the write-only argument, so the version payload is not stored in state
# again (their sources, such as random_password and the Redis AUTH string, still are). Write-only
# values are only sent when the version number changes, so it is derived from a hash of the value:
# a changed value (new Redis IP, rotated password) writes a new secret version. The hash is a
# one-way fingerprint of a high-entropy value and is safe to show in plans.
resource "google_secret_manager_secret_version" "this" {
  for_each               = local.secret_ids
  secret                 = google_secret_manager_secret.this[each.key].id
  secret_data_wo         = var.secrets[each.key]
  secret_data_wo_version = parseint(substr(nonsensitive(sha256(var.secrets[each.key])), 0, 7), 16)
}

# Read access is granted per secret, never project-wide, so readers see only these secrets.
resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = {
    for pair in setproduct(local.secret_ids, var.accessor_members) : "${pair[0]}/${pair[1]}" => {
      secret = pair[0]
      member = pair[1]
    }
  }
  secret_id = google_secret_manager_secret.this[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}
