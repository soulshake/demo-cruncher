# Note: variable values can be overridden by setting `TF_VAR_varname` environment variables, for example: `export TF_VAR_cluster=fancy`
variable "cluster" {
  default     = "default"
  description = "Name of the cluster where resources should be deployed."
  type        = string
}

variable "namespace" {
  default     = "default"
  description = "Kubernetes namespace where resources will be created."
  type        = string
}

locals {
  id          = data.aws_caller_identity.current.account_id
  oidc_issuer = replace(data.aws_eks_cluster.current.identity[0].oidc[0].issuer, "https://", "")
}

# SQS queue
resource "aws_sqs_queue" "queue" {
  name = var.namespace
}

# Roles
resource "aws_iam_role" "queue_watcher" {
  name               = "queue-watcher-${var.namespace}"
  description        = "queue-watcher role for ${var.namespace}"
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
        "system:serviceaccount:${var.namespace}:queue-watcher",
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

# Outputs
output "queue_url" {
  description = "URL of the created SQS queue."
  value       = aws_sqs_queue.queue.url
}
