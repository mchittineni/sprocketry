variable "name" {
  description = "Name prefix for the KMS key alias."
  type        = string
}

variable "topics" {
  description = "Map of topic name to the subscriber app ids (Dapr consumerIDs)."
  type        = map(list(string))

  validation {
    # Dapr sanitizes names to [A-Za-z0-9_-] and 80 characters; the DLQ suffix needs 4 more.
    condition = alltrue(concat(
      [for t in keys(var.topics) : can(regex("^[A-Za-z0-9_-]{1,80}$", t))],
      [for s in flatten(values(var.topics)) : can(regex("^[A-Za-z0-9_-]{1,76}$", s))],
    ))
    error_message = "Topic and subscriber names must match [A-Za-z0-9_-], or Dapr would look for a different name."
  }
}

variable "max_receive_count" {
  description = "Deliveries before SQS moves a message to the dead-letter queue. Keep equal to the Dapr component's messageReceiveLimit."
  type        = number
  default     = 10
}
