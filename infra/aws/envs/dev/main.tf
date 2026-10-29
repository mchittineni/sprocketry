# ==================== Locals ====================
locals {
  name = "${var.project}-${var.environment}"

  # Applied to every resource through the provider's default_tags.
  tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  app_namespace = "sprocketry"
  services      = ["storefront", "catalog", "cart", "shipping", "payment", "fulfillment", "reviews", "profile"]
  databases     = ["catalog", "shipping", "reviews", "profile", "keycloak"]

  # A fixed list, so a plan run by CI and an apply run by you agree on the same access entries.
  # The fallback is the IAM role behind your session (an assumed-role session ARN can't be an access entry).
  deployers = toset(length(var.deployer_principal_arns) > 0 ? var.deployer_principal_arns : [data.aws_iam_session_context.current.issuer_arn])
}

data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# ==================== Network ====================
module "network" {
  source = "../../modules/network"
  name   = local.name
}

# ==================== Compute ====================
module "eks" {
  source                       = "../../modules/eks"
  name                         = local.name
  subnet_ids                   = module.network.private_subnet_ids
  kubernetes_version           = var.kubernetes_version
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  admin_principal_arns         = local.deployers
  node_instance_type           = var.node_instance_type
  node_max_count               = var.node_max_count
  ecr_repositories             = toset(local.services)
}

# ==================== Data ====================
module "postgres" {
  source                  = "../../modules/postgres"
  name                    = "${local.name}-postgres"
  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.private_subnet_ids
  allowed_security_groups = { eks = module.eks.cluster_security_group_id }
  databases               = local.databases
}

module "valkey" {
  source                  = "../../modules/valkey"
  name                    = "${local.name}-valkey"
  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.private_subnet_ids
  allowed_security_groups = { eks = module.eks.cluster_security_group_id }
}

# ==================== Messaging ====================
module "messaging" {
  source = "../../modules/messaging"
  name   = local.name
  topics = { orders = ["fulfillment"] }
}

# ==================== Secrets ====================
# Keycloak's bootstrap admin, and the secret the storefront signs in to Keycloak with.
resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}

resource "random_password" "storefront_client" {
  length  = 48
  special = false
}

# Secrets Manager is the single source of truth. External Secrets Operator syncs these into Kubernetes.
module "secrets" {
  source = "../../modules/secrets"

  secrets = {
    "catalog-database-url"  = module.postgres.connection_strings["catalog"]
    "shipping-database-url" = module.postgres.connection_strings["shipping"]
    "redis-host"            = module.valkey.host
    "redis-password"        = module.valkey.auth_token
    "reviews-database-url"  = module.postgres.connection_strings["reviews"]
    "profile-database-url"  = module.postgres.connection_strings["profile"]
    # Keycloak uses the master login: the AWS provider can't create PostgreSQL roles. Give it its own
    # role (e.g. with the postgresql provider, run from inside the VPC) for anything beyond dev.
    "keycloak-db-url"          = module.postgres.jdbc_urls["keycloak"]
    "keycloak-db-username"     = module.postgres.admin_login
    "keycloak-db-password"     = module.postgres.admin_password
    "keycloak-admin-password"  = random_password.keycloak_admin.result
    "storefront-client-secret" = random_password.storefront_client.result
  }
}

# ==================== Pod Identity ====================
locals {
  # What Dapr's pubsub.aws.snssqs calls with disableEntityManagement on (see the messaging module):
  # payment publishes, fulfillment consumes and looks up its dead-letter queue by name.
  apps_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishAndLookUpTopics"
        Effect   = "Allow"
        Action   = ["sns:Publish", "sns:GetTopicAttributes", "sns:ListSubscriptionsByTopic"]
        Resource = values(module.messaging.topic_arns)
      },
      {
        Sid      = "ConsumeQueues"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = values(module.messaging.queue_arns)
      },
      {
        Sid      = "LookUpDeadLetterQueues"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = values(module.messaging.dead_letter_queue_arns)
      },
      {
        # Publishing to an encrypted topic and reading an encrypted queue both use the pub/sub key.
        Sid      = "UsePubSubKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = module.messaging.kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = ["sns.${var.region}.amazonaws.com", "sqs.${var.region}.amazonaws.com"]
          }
        }
      },
    ]
  })

  # Read-only on exactly the secrets above. ListSecrets and BatchGetSecretValue (only needed for
  # dataFrom.find) and the PushSecret write actions are left out on purpose.
  external_secrets_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadSprocketrySecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = values(module.secrets.arns)
    }]
  })
}

module "pod_identity" {
  source       = "../../modules/pod-identity"
  name_prefix  = local.name
  cluster_name = module.eks.cluster_name
  cluster_arn  = module.eks.cluster_arn

  identities = {
    # Used by the Dapr sidecars of the services that publish or consume events.
    apps = {
      namespace        = local.app_namespace
      service_accounts = ["payment", "fulfillment"]
      policy           = local.apps_policy
    }
    # Used by External Secrets Operator to read Secrets Manager.
    external-secrets = {
      namespace        = "external-secrets"
      service_accounts = ["external-secrets"]
      policy           = local.external_secrets_policy
    }
  }
}
