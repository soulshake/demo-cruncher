locals {
  id          = data.aws_caller_identity.current.account_id
  oidc_issuer = replace(data.aws_eks_cluster.default.identity[0].oidc[0].issuer, "https://", "")
}

# SQS queue
resource "aws_sqs_queue" "queue" {
  name = terraform.workspace
}

# Roles
resource "aws_iam_role" "queue_watcher" {
  name               = "queue-watcher-${terraform.workspace}"
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
        "system:serviceaccount:${terraform.workspace}:queue-watcher",
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
