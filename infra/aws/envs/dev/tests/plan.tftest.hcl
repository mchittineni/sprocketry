# Offline plan tests: aws and random are mocked, so these need no AWS credentials and create nothing.
# Run with `terraform test`. They prove the configuration plans with the pinned provider and that the
# security settings hold. Real API behaviour (e.g. whether a Valkey version exists in the region) still
# needs a real plan.

# override_during = plan makes the defaults below known at plan time. Computed attributes without a
# default stay unknown, so the ARNs that the IAM policies are built from get one per resource type, and
# the policy assertions compare against those. (Per-instance override_resource blocks would give every
# secret its own ARN, at eleven blocks for little extra proof: the exact names are asserted separately.)
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:sts::123456789012:assumed-role/Deployer/session"
      user_id    = "AROAEXAMPLE:session"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/Deployer"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:mock-AbCdEf"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-west-2:123456789012:mock-topic"
    }
  }

  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:eu-west-2:123456789012:mock-queue"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-2:123456789012:key/11111111-1111-1111-1111-111111111111"
    }
  }

  # The registry host is taken from a repository URL, so it needs a realistic one.
  mock_resource "aws_ecr_repository" {
    defaults = {
      repository_url = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/storefront"
    }
  }
}

mock_provider "random" {
  override_during = plan

  mock_resource "random_password" {
    defaults = {
      result = "mockpasswordmockpasswordmockpass"
    }
  }
}

variables {
  owner                                = "tests@example.com"
  cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
}

# ---------- Whole environment ----------

run "environment_plans_with_explicit_deployers" {
  command = plan

  variables {
    deployer_principal_arns = ["arn:aws:iam::123456789012:role/alice", "arn:aws:iam::123456789012:role/ci"]
  }

  assert {
    condition     = local.deployers == toset(["arn:aws:iam::123456789012:role/alice", "arn:aws:iam::123456789012:role/ci"])
    error_message = "Explicit deployers should be used as given."
  }

  assert {
    condition     = output.ecr_registry == "123456789012.dkr.ecr.eu-west-2.amazonaws.com"
    error_message = "ecr_registry should be the registry host, without a repository path."
  }

  # The chart's ExternalSecret maps these names 1:1, so the set must match exactly.
  assert {
    condition = toset(keys(module.secrets.arns)) == toset([
      "catalog-database-url", "shipping-database-url", "redis-host", "redis-password",
      "reviews-database-url", "profile-database-url", "keycloak-db-url", "keycloak-db-username",
      "keycloak-db-password", "keycloak-admin-password", "storefront-client-secret",
    ])
    error_message = "Secrets Manager must hold exactly the 11 secrets the chart reads."
  }

  assert {
    condition     = length(jsondecode(local.external_secrets_policy).Statement) == 1
    error_message = "The External Secrets policy should be a single statement."
  }

  assert {
    condition     = length(jsondecode(local.external_secrets_policy).Statement[0].Resource) == 11 && alltrue([for r in jsondecode(local.external_secrets_policy).Statement[0].Resource : contains(values(module.secrets.arns), r)])
    error_message = "External Secrets may read exactly the environment's secrets, nothing else."
  }

  assert {
    condition     = toset(jsondecode(local.external_secrets_policy).Statement[0].Action) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    error_message = "External Secrets should only be able to read secrets."
  }

  # Every resource the apps role touches is one of the pub/sub entities or their key.
  assert {
    condition = alltrue([
      for s in jsondecode(local.apps_policy).Statement : alltrue([
        for r in flatten([s.Resource]) : contains(concat(
          values(module.messaging.topic_arns),
          values(module.messaging.queue_arns),
          values(module.messaging.dead_letter_queue_arns),
          [module.messaging.kms_key_arn],
        ), r)
      ])
    ])
    error_message = "The apps role may only touch the pub/sub topics, queues and their key."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(local.apps_policy).Statement : alltrue([
        for a in flatten([s.Action]) : !strcontains(a, "*") && !contains(["sns:CreateTopic", "sns:Subscribe", "sqs:CreateQueue", "sqs:SetQueueAttributes"], a)
      ])
    ])
    error_message = "The apps role must not manage entities (disableEntityManagement) or use wildcard actions."
  }

  assert {
    condition = module.pod_identity.associations == {
      "apps/payment"                      = "sprocketry/payment"
      "apps/fulfillment"                  = "sprocketry/fulfillment"
      "external-secrets/external-secrets" = "external-secrets/external-secrets"
    }
    error_message = "Pod identities must bind exactly the payment and fulfillment sidecars and the External Secrets controller."
  }
}

run "environment_plans_with_caller_fallback" {
  command = plan

  variables {
    deployer_principal_arns = []
  }

  assert {
    condition     = local.deployers == toset(["arn:aws:iam::123456789012:role/Deployer"])
    error_message = "With no deployers given, the role behind the caller's session should be the admin."
  }
}

# ---------- Modules ----------

run "network_keeps_public_subnets_for_load_balancers" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    name = "sprocketry-test"
  }

  assert {
    condition     = length(aws_subnet.private) == 2 && length(aws_subnet.public) == 2
    error_message = "Two AZs of private and public subnets are expected."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "Public subnets must not hand out public IPs by default."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Public subnets need the elb role tag so Kubernetes places internet-facing load balancers there."
  }
}

run "eks_uses_access_entries_and_pod_identity" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    name                         = "sprocketry-test"
    subnet_ids                   = ["subnet-aaaa", "subnet-bbbb"]
    endpoint_public_access_cidrs = []
    admin_principal_arns         = ["arn:aws:iam::123456789012:role/alice", "arn:aws:iam::123456789012:role/ci"]
    ecr_repositories             = ["storefront", "catalog"]
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    error_message = "Cluster access must come only from the access entries managed here."
  }

  assert {
    condition     = !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    error_message = "An empty CIDR list must make the API endpoint private-only."
  }

  assert {
    condition     = length(aws_eks_access_policy_association.admin) == 2
    error_message = "Each deployer should get cluster admin."
  }

  assert {
    condition     = aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent"
    error_message = "The Pod Identity agent add-on is required for the pod identity associations."
  }

  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Pods must not reach the node role through IMDS."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_scanning_configuration[0].scan_on_push])
    error_message = "ECR must scan images on push."
  }
}

run "postgres_is_private_and_encrypted" {
  command = plan

  module {
    source = "../../modules/postgres"
  }

  variables {
    name                    = "sprocketry-test-postgres"
    vpc_id                  = "vpc-1234"
    subnet_ids              = ["subnet-aaaa", "subnet-bbbb"]
    allowed_security_groups = { eks = "sg-cluster" }
    databases               = ["catalog", "shipping"]
  }

  assert {
    condition     = !aws_db_instance.this.publicly_accessible
    error_message = "RDS must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted
    error_message = "RDS storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "18"
    error_message = "RDS should run PostgreSQL 18."
  }

  assert {
    condition     = aws_db_instance.this.db_name == "catalog"
    error_message = "RDS creates the first listed database."
  }

  assert {
    condition     = [for r in aws_vpc_security_group_ingress_rule.this : r.referenced_security_group_id] == ["sg-cluster"]
    error_message = "Only the cluster security group may reach PostgreSQL."
  }
}

run "valkey_requires_tls_and_auth" {
  command = plan

  module {
    source = "../../modules/valkey"
  }

  variables {
    name                    = "sprocketry-test-valkey"
    vpc_id                  = "vpc-1234"
    subnet_ids              = ["subnet-aaaa", "subnet-bbbb"]
    allowed_security_groups = { eks = "sg-cluster" }
  }

  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled && aws_elasticache_replication_group.this.transit_encryption_mode == "required"
    error_message = "Valkey must refuse plaintext connections."
  }

  assert {
    condition     = length(nonsensitive(aws_elasticache_replication_group.this.auth_token)) >= 16
    error_message = "Valkey must require an AUTH token."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.at_rest_encryption_enabled
    error_message = "Valkey data must be encrypted at rest."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.engine == "valkey" && aws_elasticache_replication_group.this.num_cache_clusters == 1
    error_message = "Dev runs a single Valkey node with cluster mode disabled."
  }
}

run "messaging_matches_dapr_snssqs_names" {
  command = plan

  module {
    source = "../../modules/messaging"
  }

  variables {
    name   = "sprocketry-test"
    topics = { orders = ["fulfillment"] }
  }

  assert {
    condition     = aws_sns_topic.this["orders"].name == "orders"
    error_message = "The SNS topic must be named after the Dapr topic."
  }

  assert {
    condition     = aws_sqs_queue.this["fulfillment"].name == "fulfillment"
    error_message = "The SQS queue must be named after the subscriber's consumerID (its app id)."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter["fulfillment"].name == "fulfillment-dlq"
    error_message = "The dead-letter queue name is what the component's sqsDeadLettersQueueName points at."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.this["fulfillment"].redrive_policy).maxReceiveCount == 10
    error_message = "SQS should redrive after 10 receives, matching messageReceiveLimit."
  }

  assert {
    condition     = aws_sns_topic_subscription.this["orders/fulfillment"].protocol == "sqs" && !aws_sns_topic_subscription.this["orders/fulfillment"].raw_message_delivery
    error_message = "Dapr needs an SQS subscription with the SNS envelope (no raw delivery)."
  }

  assert {
    condition     = aws_sns_topic.this["orders"].kms_master_key_id == aws_kms_key.this.arn && aws_sqs_queue.this["fulfillment"].kms_master_key_id == aws_kms_key.this.arn
    error_message = "Topics and queues must be encrypted with the pub/sub key."
  }
}

run "secrets_are_written_under_their_own_names" {
  command = plan

  module {
    source = "../../modules/secrets"
  }

  variables {
    secrets = {
      "catalog-database-url" = "postgres://example"
      "redis-password"       = "example"
    }
  }

  assert {
    condition     = toset([for s in aws_secretsmanager_secret.this : s.name]) == toset(["catalog-database-url", "redis-password"])
    error_message = "Each secret should be named exactly as its key, with no prefix."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 2
    error_message = "Every secret passed in should get a value."
  }
}

run "pod_identity_trusts_only_the_cluster" {
  command = plan

  module {
    source = "../../modules/pod-identity"
  }

  variables {
    name_prefix  = "sprocketry-test"
    cluster_name = "sprocketry-test"
    cluster_arn  = "arn:aws:eks:eu-west-2:123456789012:cluster/sprocketry-test"
    identities = {
      external-secrets = {
        namespace        = "external-secrets"
        service_accounts = ["external-secrets"]
        policy           = "{}"
      }
    }
  }

  assert {
    condition     = aws_eks_pod_identity_association.this["external-secrets/external-secrets"].namespace == "external-secrets" && aws_eks_pod_identity_association.this["external-secrets/external-secrets"].service_account == "external-secrets"
    error_message = "The association must bind the given namespace and service account."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this["external-secrets"].assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "Roles must be assumable only by the EKS Pod Identity agent."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this["external-secrets"].assume_role_policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == "arn:aws:eks:eu-west-2:123456789012:cluster/sprocketry-test"
    error_message = "The trust policy must be scoped to this cluster."
  }
}
