output "region" {
  value = var.region
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

# Registry host CI pushes to and the chart pulls from, e.g. 123456789012.dkr.ecr.eu-west-2.amazonaws.com.
output "ecr_registry" {
  value = module.eks.ecr_registry
}

# The Dapr pubsub component's sqsDeadLettersQueueName for each subscriber. Topic and queue names need no
# output: Dapr derives them from the topic name and the app id.
output "pubsub_dead_letter_queues" {
  value = module.messaging.dead_letter_queue_names
}

# RDS creates only the first of these. The rest must be created from inside the VPC, e.g. by a one-off
# in-cluster Job that connects with the credentials in catalog-database-url to the `postgres` database.
output "postgres_databases" {
  value = local.databases
}

output "pod_identity_role_arns" {
  value = module.pod_identity.role_arns
}
