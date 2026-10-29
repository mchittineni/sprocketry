# Keyed by topic name.
output "topic_names" {
  value = { for k, v in google_pubsub_topic.this : k => v.name }
}

# Keyed by "<topic>/<subscriber app id>".
output "subscription_names" {
  value = { for k, v in google_pubsub_subscription.this : k => v.name }
}
