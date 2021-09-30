/*
 * This directory contains everything needed to run one instantiation of the demo app.
 * Each Terraform workspace corresponds to a Kubernetes namespace, a dedicated SQS queue and `queue-watcher` deployment, and IAM roles with permissions scoped to these resources.
 * For example, to create a `staging` and `production` environment, you could run:
 *
 * ```
 * terraform workspace new staging
 * make plan
 * make apply
 *
 * terraform workspace new production
 * make plan
 * make apply
 * ```
 *
 */

variable "max_pending" {
  default     = 10
  description = "Maximum number of pending pods to tolerate before we stop creating new jobs."
  type        = number
}

locals {
  id          = data.aws_caller_identity.current.account_id
  namespace   = "demo-${terraform.workspace}"
  oidc_issuer = replace(data.aws_eks_cluster.demo.identity[0].oidc[0].issuer, "https://", "")
  region      = data.aws_region.current.name

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

# SQS queue
resource "aws_sqs_queue" "queue" {
  name = local.namespace
}

# Kubernetes resources
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
          name              = "queue-watcher"
          env {
            name  = "MAX_PENDING"
            value = var.max_pending
          }
          env {
            name  = "QUEUE_URL"
            value = aws_sqs_queue.queue.url
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "500Mi"
            }
          }
        }
      }
    }
  }
  provider = kubernetes.demo
}

# Roles
resource "aws_iam_role" "queue_watcher" {
  name               = "demo-queue-watcher-${terraform.workspace}"
  description        = "queue-watcher role for ${terraform.workspace}"
  assume_role_policy = trimspace(data.aws_iam_policy_document.assume_role_with_oidc.json)
}

data "aws_iam_policy_document" "assume_role_with_oidc" {
  # Allow cluster to authenticate roles via its OIDC provider.
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
        "system:serviceaccount:${local.namespace}:queue-watcher",
      ]
    }
  }
}

# Policies
resource "aws_iam_policy" "queue_watcher" {
  name        = "${aws_iam_role.queue_watcher.name}-policy"
  description = "Allows access to resources needed by ${aws_iam_role.queue_watcher.name} for the demo pipeline."
  policy      = data.aws_iam_policy_document.queue_watcher.json
}


data "aws_iam_policy_document" "queue_watcher" {
  statement {
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

resource "aws_iam_role_policy_attachment" "queue_watcher" {
  role       = aws_iam_role.queue_watcher.name
  policy_arn = aws_iam_policy.queue_watcher.arn
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

# Outputs
output "queue_url" {
  description = "URL of the created SQS queue."
  value       = aws_sqs_queue.queue.url
}
