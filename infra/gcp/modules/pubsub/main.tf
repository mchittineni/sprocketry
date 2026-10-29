# ==================== Pub/Sub ====================
resource "google_pubsub_topic" "this" {
  for_each = var.topics
  name     = each.key
}

# Dapr's pubsub.gcp.pubsub names a subscription "<consumerID>-<topic>", and consumerID defaults to the
# app id (components-contrib release-1.18, pubsub/gcp/pubsub/pubsub.go: BuildSubscriptionID). With
# disableEntityManagement it only attaches to existing entities, so pre-creating them lets the apps
# run with publish/consume rights only, not Pub/Sub admin.
resource "google_pubsub_subscription" "this" {
  for_each = {
    for pair in flatten([
      for topic, subs in var.topics : [for sub in subs : { topic = topic, sub = sub }]
    ]) : "${pair.topic}/${pair.sub}" => pair
  }
  name  = "${each.value.sub}-${each.value.topic}"
  topic = google_pubsub_topic.this[each.value.topic].id

  # Dapr's default ackDeadline; the client extends leases while a handler is still running.
  ack_deadline_seconds = 20

  # Never expire: by default an idle subscription is deleted after 31 days, which a paused dev
  # environment easily hits.
  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}
