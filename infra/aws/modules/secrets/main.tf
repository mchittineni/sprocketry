# ==================== Secrets Manager ====================
# One secret per key, named exactly as the chart's ExternalSecret asks for them (no prefix), so one
# environment per account and region. Encrypted with the AWS managed key, which readers can use
# through Secrets Manager without a key grant.
resource "aws_secretsmanager_secret" "this" {
  # Keys are not secret; only values are. for_each cannot iterate a sensitive map directly.
  for_each = nonsensitive(toset(keys(var.secrets)))
  name     = each.key

  # Deleted immediately rather than after a 7-30 day recovery window, so the dev environment can be
  # destroyed and recreated under the same names. Use a recovery window for long-lived environments.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each      = aws_secretsmanager_secret.this
  secret_id     = each.value.id
  secret_string = var.secrets[each.key]
}
