locals {
  id          = data.aws_caller_identity.current.account_id
  namespace   = "demo-${terraform.workspace}"
  oidc_issuer = replace(data.aws_eks_cluster.demo.identity[0].oidc[0].issuer, "https://", "")
  region      = data.aws_region.current.name
  tags        = {} # additional tags to be added to AWS resources

  labels = {
    workspace = terraform.workspace
  }
  cruncher_labels = merge(local.labels, {
    app = "cruncher"
  })
  queue_watcher_labels = merge(local.labels, {
    app = "queue-watcher"
  })
}

###
### Queues
###

# Primary DEEPGEN queue (for this ${terraform.workspace} environment)
resource "aws_sqs_queue" "queue" {
  name = local.namespace
  tags = local.tags
  # content_based_deduplication = true
  # deduplication_scope         = "messageGroup" # must be messageGroup if throughput limit is set to 'perMessageGroupId'
  # fifo_queue                  = true
  # fifo_throughput_limit       = "perMessageGroupId" # this allows parallel processing because each sample has a unique message group ID
  # message_retention_seconds   = 1209600             # 14 days (max)
  # visibility_timeout_seconds  = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deadletter.arn
    maxReceiveCount     = 4
  })
}
resource "aws_sqs_queue" "deadletter" {
  name = "${local.namespace}-deadletter"
  tags = local.tags
}

###
### Kubernetes resources
###
resource "kubernetes_namespace" "ns" {
  metadata {
    name = local.namespace
  }
  provider = kubernetes.demo
}

resource "kubernetes_deployment" "queue_watcher" {
  wait_for_rollout = false

  metadata {
    name      = "queue-watcher"
    namespace = kubernetes_namespace.ns.metadata.0.name
    labels    = local.queue_watcher_labels
    annotations = {
      "cluster-autoscaler.kubernetes.io/safe-to-evict" = true
    }
  }

  spec {
    selector {
      match_labels = local.queue_watcher_labels
    }

    template {
      metadata {
        labels = local.queue_watcher_labels
      }

      spec {
        service_account_name            = kubernetes_service_account.queue_watcher.metadata.0.name
        automount_service_account_token = true
        container {
          image             = "${local.id}.dkr.ecr.${local.region}.amazonaws.com/queue-watcher:${terraform.workspace}"
          image_pull_policy = "Always"
          args              = ["watch"]
          name              = "queue-watcher"
          env {
            name  = "IMAGE_TAG"
            value = terraform.workspace
          }
          env {
            name  = "QUEUE_URL"
            value = aws_sqs_queue.queue.url
          }
          env {
            name  = "WORKSPACE"
            value = terraform.workspace
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "500Mi"
            }
          }
        }
        # node_selector = {
        # role = "queue-watcher"
        # }
      }
    }
  }
  provider = kubernetes.demo
}

# Roles
resource "aws_iam_role" "cruncher" {
  name               = "demo-cruncher-${terraform.workspace}"
  description        = "cruncher role for ${terraform.workspace}"
  assume_role_policy = trimspace(data.aws_iam_policy_document.assume_role_with_oidc.json)
  tags               = local.tags
  # max_session_duration = 43200
}

resource "aws_iam_role" "queue_watcher" {
  name               = "demo-queue-watcher-${terraform.workspace}"
  description        = "queue-watcher role for ${terraform.workspace}"
  assume_role_policy = trimspace(data.aws_iam_policy_document.assume_role_with_oidc.json)
  tags               = local.tags
  # max_session_duration = 43200
}

data "aws_iam_policy_document" "assume_role_with_oidc" {
  # Allow cluster to authenticate roles via its OIDC provider.
  # Tip: use local references within policy documents to avoid '(known after apply)' when planning.
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type = "Federated"
      identifiers = [
        "arn:aws:iam::${local.id}:oidc-provider/${local.oidc_issuer}"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values = [
        "system:serviceaccount:${local.namespace}:cruncher",
        "system:serviceaccount:${local.namespace}:queue-watcher",
      ]
    }
  }
}

# Policies
resource "aws_iam_policy" "cruncher" {
  name        = "${aws_iam_role.cruncher.name}-policy" # role name already includes workspace
  description = "Allows access to resources needed by ${aws_iam_role.cruncher.name} for the demo pipeline."
  policy      = data.aws_iam_policy_document.cruncher.json
  tags        = local.tags
}

resource "aws_iam_policy" "queue_watcher" {
  name        = "${aws_iam_role.queue_watcher.name}-policy"
  description = "Allows access to resources needed by ${aws_iam_role.queue_watcher.name} for the demo pipeline."
  policy      = data.aws_iam_policy_document.queue_watcher.json
  tags        = local.tags
}

data "aws_iam_policy_document" "cruncher" {
  statement {
    sid = "CanReadEcr"
    actions = [
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [
      "*",
    ]
    # Can add conditions here to restrict scope to resources created in this workspace
  }
  statement {
    # Access to the resource https://sqs.eu-central-1.amazonaws.com/ is denied.
    sid = "CanPopMessages"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [
      aws_sqs_queue.queue.arn,
    ]
  }
}

data "aws_iam_policy_document" "queue_watcher" {
  statement {
    sid = "CanReadEcr"
    actions = [
      "ecr:Nothing",
      # "ecr:BatchCheckLayerAvailability",
      # "ecr:BatchGetImage",
      # "ecr:DescribeImageScanFindings",
      # "ecr:DescribeImages",
      # "ecr:DescribeRepositories",
      # "ecr:GetDownloadUrlForLayer",
      # "ecr:GetLifecyclePolicy",
      # "ecr:GetLifecyclePolicyPreview",
      # "ecr:GetRepositoryPolicy",
      # "ecr:ListImages",
      # "ecr:ListTagsForResource",
    ]
    resources = [
      "*",
    ]
  }

  # Allow SQS
  statement {
    # Unsure if this one is needed
    sid       = "CanListQueues"
    actions   = ["sqs:ListQueues"]
    resources = ["*"]
  }

  statement {
    sid = "CanDescribeQueue"
    actions = [
      "sqs:GetQueueAttributes",
      # "sqs:*",
    ]
    resources = [
      aws_sqs_queue.queue.arn,
    ]
    # Can add conditions here to restrict scope to resources created in this workspace
  }
}

resource "aws_iam_role_policy_attachment" "cruncher" {
  role       = aws_iam_role.cruncher.name
  policy_arn = aws_iam_policy.cruncher.arn
}

resource "aws_iam_role_policy_attachment" "queue_watcher" {
  role       = aws_iam_role.queue_watcher.name
  policy_arn = aws_iam_policy.queue_watcher.arn
}

# service accounts
resource "kubernetes_service_account" "cruncher" {
  automount_service_account_token = true
  metadata {
    name      = "cruncher"
    namespace = kubernetes_namespace.ns.metadata.0.name
    labels    = local.cruncher_labels
    annotations = {
      "eks.amazonaws.com/role-arn" : aws_iam_role.cruncher.arn
    }
  }
  provider = kubernetes.demo
}

resource "kubernetes_service_account" "queue_watcher" {
  automount_service_account_token = true
  metadata {
    name      = "queue-watcher"
    namespace = kubernetes_namespace.ns.metadata.0.name
    labels    = local.queue_watcher_labels
    annotations = {
      "eks.amazonaws.com/role-arn" : aws_iam_role.queue_watcher.arn
    }
  }
  provider = kubernetes.demo
}

# Role bindings
#
# Note: No role binding needed for cruncher
#
resource "kubernetes_role_binding" "queue_watcher" {
  # Needs to be able to create pods
  metadata {
    name      = "edit-${local.namespace}"
    namespace = kubernetes_namespace.ns.metadata.0.name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }
  subject {
    # associates the iam role with the corresponding k8s "user" even if no mapping is present in aws-auth configmap
    kind      = "User"
    name      = aws_iam_role.queue_watcher.arn
    api_group = "rbac.authorization.k8s.io"
    namespace = kubernetes_namespace.ns.metadata.0.name
  }
  # allows this service account to run `kubectl create`
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.queue_watcher.metadata.0.name
    api_group = ""
    namespace = kubernetes_namespace.ns.metadata.0.name
  }
  provider = kubernetes.demo
}
