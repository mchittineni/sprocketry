variable "secrets" {
  description = "Secrets to store, keyed by Secrets Manager secret name."
  type        = map(string)
  sensitive   = true
}
