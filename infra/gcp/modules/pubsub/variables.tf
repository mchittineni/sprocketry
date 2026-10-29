variable "topics" {
  description = "Map of topic name to the subscriber app ids (Dapr consumerIDs)."
  type        = map(list(string))
}
