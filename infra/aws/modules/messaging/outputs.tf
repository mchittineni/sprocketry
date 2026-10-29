output "topic_arns" {
  value = { for k, v in aws_sns_topic.this : k => v.arn }
}

output "queue_arns" {
  value = { for k, v in aws_sqs_queue.this : k => v.arn }
}

output "dead_letter_queue_arns" {
  value = { for k, v in aws_sqs_queue.dead_letter : k => v.arn }
}

output "dead_letter_queue_names" {
  value = { for k, v in aws_sqs_queue.dead_letter : k => v.name }
}

output "kms_key_arn" {
  value = aws_kms_key.this.arn
}
