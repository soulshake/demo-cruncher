locals {
  tags = {}
  name = "demo"
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-state-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = local.tags
}


resource "aws_key_pair" "demo" {
  key_name   = "demo-aj"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDKNEtKIF8/e84xCQJ9ay0XF0FWtpDiixqwTwlvvMxihv6zO7DgxFxmLSb1l621U0mKsRu7O5GRqPnUfv2ppEypnP/ifgxS9Ffc/AxbwtLdcjlZ3y3gCC/lvUs7pbw/zJTNFS1lC5e5xrzpCXiGmG14LtTAC2Y+BnFedk4xAIL1T1BiEJfl6+l8JY4gk6yKhmLcExOFvlHnVZupxYYriuK3XmvKN/6ndj5fc3IrGtQEoQPXZi9kBbtQB9qluFKHcP3Xv6EJwc1DDFXSxxK6hjOYq4T4cHQEgBYB4HMrYD/00BXHWJvcCxdy025DrHoyUEKYYOl41U2ydLXwBN/WxFPN aj@soulshake.net"
}

# Permissions
resource "aws_iam_role" "control_plane" {
  # Allows access to other AWS service resources that are required to operate clusters managed by EKS.
  name = "${local.name}-control-plane"
  tags = local.tags

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "control_plane_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = one(aws_iam_role.control_plane[*].name)
}

resource "aws_iam_role_policy_attachment" "control_plane_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = one(aws_iam_role.control_plane[*].name)
}

# Worker roles
resource "aws_iam_role" "node" {
  name = "${local.name}-node"
  tags = local.tags

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "cloudwatch_policy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = one(aws_iam_role.node[*].name)
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = one(aws_iam_role.node[*].name)
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = one(aws_iam_role.node[*].name)
}

resource "aws_iam_role_policy_attachment" "node_container_registry_ro" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = one(aws_iam_role.node[*].name)
}

resource "aws_iam_instance_profile" "nodes" {
  name = local.name
  role = one(aws_iam_role.node[*].name)
  tags = local.tags
}

