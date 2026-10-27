variable "name" {
  description = "Service Bus namespace name (globally unique)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "topics" {
  description = "Map of topic name to the subscriber app ids."
  type        = map(list(string))
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
