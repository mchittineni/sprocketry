variable "secrets" {
  description = "Secrets to store, keyed by Secret Manager secret ID."
  type        = map(string)
  sensitive   = true
}

variable "accessor_members" {
  description = "IAM members allowed to read every secret in this module (and only those)."
  type        = set(string)
  default     = []
}
