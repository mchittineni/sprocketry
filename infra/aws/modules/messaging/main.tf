# ==================== SNS + SQS for Dapr pub/sub ====================
# With disableEntityManagement, Dapr's pubsub.aws.snssqs only looks entities up, so their names must match
# what it would have created (components-contrib release-1.18, pubsub/aws/snssqs/snssqs.go):
#   topic        = the topic name, looked up as arn:<partition>:sns:<region>:<account>:<topic>
#   queue        = the consumerID, which defaults to the subscribing app id
#   subscription = any SNS subscription on the topic (ListSubscriptionsByTopic)
# Names pass through nameToAWSSanitizedName (keeps [A-Za-z0-9_-], max 80), so the variable validation
# below only accepts names that sanitizing leaves unchanged.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  subscribers = toset(flatten(values(var.topics)))
  subscriptions = {
    for pair in flatten([
      for topic, subs in var.topics : [for sub in subs : { topic = topic, sub = sub }]
    ]) : "${pair.topic}/${pair.sub}" => pair
  }
}

# One key for topics and queues. SNS must be able to use it to deliver into the encrypted queues.
resource "aws_kms_key" "this" {
  description             = "${var.name} pub/sub encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Account-wide IAM control, as in the default key policy, so role policies can grant use of the key.
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "SnsDeliveryToEncryptedQueues"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
    ]
  })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-pubsub"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_sns_topic" "this" {
  for_each          = var.topics
  name              = each.key
  kms_master_key_id = aws_kms_key.this.arn
}

# Messages Dapr gives up on land here. Dapr finds this queue by name (sqsDeadLettersQueueName) but
# leaves the redrive to SQS when entity management is off, so the redrive policy below does it.
resource "aws_sqs_queue" "dead_letter" {
  for_each                  = local.subscribers
  name                      = "${each.key}-dlq"
  kms_master_key_id         = aws_kms_key.this.arn
  message_retention_seconds = 1209600 # 14 days, the maximum, to give time to inspect failures
}

resource "aws_sqs_queue" "this" {
  for_each          = local.subscribers
  name              = each.key
  kms_master_key_id = aws_kms_key.this.arn

  # Must match the component's messageReceiveLimit, so SQS moves a message exactly when Dapr stops retrying.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Only the topics this app subscribes to may write to its queue. Dapr would set this itself if it managed entities.
resource "aws_sqs_queue_policy" "this" {
  for_each  = local.subscribers
  queue_url = aws_sqs_queue.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSubscribedTopics"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.this[each.key].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [for k, s in local.subscriptions : aws_sns_topic.this[s.topic].arn if s.sub == each.key]
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "this" {
  for_each  = local.subscriptions
  topic_arn = aws_sns_topic.this[each.value.topic].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.this[each.value.sub].arn
  # Dapr reads the topic from the SNS envelope to route the message, so raw delivery must stay off.
  raw_message_delivery = false

  depends_on = [aws_sqs_queue_policy.this]
}
