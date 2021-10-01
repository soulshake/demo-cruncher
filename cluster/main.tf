/*
 * This directory contains the definitions for an EKS cluster, node group, associated IAM roles/policies, etc. This directory need only be instantiated once.
 */

variable "public_key" {
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDKNEtKIF8/e84xCQJ9ay0XF0FWtpDiixqwTwlvvMxihv6zO7DgxFxmLSb1l621U0mKsRu7O5GRqPnUfv2ppEypnP/ifgxS9Ffc/AxbwtLdcjlZ3y3gCC/lvUs7pbw/zJTNFS1lC5e5xrzpCXiGmG14LtTAC2Y+BnFedk4xAIL1T1BiEJfl6+l8JY4gk6yKhmLcExOFvlHnVZupxYYriuK3XmvKN/6ndj5fc3IrGtQEoQPXZi9kBbtQB9qluFKHcP3Xv6EJwc1DDFXSxxK6hjOYq4T4cHQEgBYB4HMrYD/00BXHWJvcCxdy025DrHoyUEKYYOl41U2ydLXwBN/WxFPN aj@soulshake.net"
  description = "Public key to provision on nodes."
}

variable "availability_zones" {
  default     = ["a", "b", "c"]
  description = "Availability zones in which to create node groups. Should be provided in the form of letter identifiers (a,b,c); these are appended to name of the active region in order to construct the AZ names."
  type        = list(string)
}

locals {
  availability_zones = [for letter in var.availability_zones : "${local.region}${letter}"]
  aws                = 1
  id                 = data.aws_caller_identity.current.account_id
  name               = terraform.workspace
  region             = data.aws_region.current.name
}

###
### Cluster
###

resource "aws_eks_cluster" "current" {
  name                      = local.name
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  role_arn                  = aws_iam_role.roles["control-plane"].arn
  version                   = "1.21"

  vpc_config {
    security_group_ids = [aws_security_group.control_plane.id]
    subnet_ids         = aws_subnet.cluster.*.id
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster, # Otherwise it gets created automatically, causing a conflict
    aws_iam_role_policy_attachment.control_plane_cluster_policy,
    aws_subnet.nodes,
  ]
}

resource "aws_cloudwatch_log_group" "cluster" {
  # Reference: https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 30
}

data "tls_certificate" "cluster" {
  # Used for obtaining the thumbprints provided to the OIDC provider
  # h/t https://marcincuber.medium.com/amazon-eks-with-oidc-provider-iam-roles-for-kubernetes-services-accounts-59015d15cb0c
  url = aws_eks_cluster.current.identity.0.oidc.0.issuer
}

resource "aws_iam_openid_connect_provider" "default" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates.0.sha1_fingerprint]
  url             = aws_eks_cluster.current.identity.0.oidc.0.issuer
  tags = {
    Name = "${local.name}-oidc-provider"
  }
}

# Networking
resource "aws_vpc" "current" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "cluster" {
  count = length(local.availability_zones)

  availability_zone       = local.availability_zones[count.index]
  cidr_block              = "10.0.${count.index}.0/24" # Create 3 adjacent /24 subnets (i.e. 256 addresses each) for the control plane components
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.current.id

  tags = {
    Name = "${local.name}-${local.availability_zones[count.index]}"
    # The following tag is needed for EKS as described here: https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
    "kubernetes.io/cluster/${local.name}" = "shared"
  }
}

resource "aws_subnet" "nodes" {
  count = length(local.availability_zones)

  availability_zone       = local.availability_zones[count.index]
  cidr_block              = "10.0.${(count.index + 1) * 16}.0/20" # Create 3 adjacent /20 subnets (i.e. 4,096 addresses each) for the node groups
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.current.id
  tags = {
    Name = "${local.name}-nodes-${local.availability_zones[count.index]}"
    # The following tag is needed for EKS as described here: https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
    "kubernetes.io/cluster/${local.name}" = "shared" # https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
  }
}

resource "aws_internet_gateway" "current" {
  vpc_id = aws_vpc.current.id
}

resource "aws_route_table" "current" {
  vpc_id = aws_vpc.current.id
}

resource "aws_route" "current" {
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.current.id
  route_table_id         = aws_route_table.current.id
}

resource "aws_route_table_association" "current" {
  count          = length(local.availability_zones)
  route_table_id = aws_route_table.current.id
  subnet_id      = aws_subnet.cluster[count.index].id
}

resource "aws_route_table_association" "nodes" {
  count          = length(local.availability_zones)
  route_table_id = aws_route_table.current.id
  subnet_id      = aws_subnet.nodes[count.index].id
}

resource "aws_security_group" "control_plane" {
  description = "Cluster communication with worker nodes."
  name        = "${local.name}-security-group"
  vpc_id      = aws_vpc.current.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "control_plane_ingress_apiserver_public" {
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow public internet access to cluster API Server."
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.control_plane.id
  to_port           = 443
  type              = "ingress"
}

###
### Node groups
###

# Public key for SSH access to nodes
resource "aws_key_pair" "current" {
  key_name   = "${local.name}-key"
  public_key = var.public_key
}

resource "aws_eks_node_group" "ng" {
  # all instances in node group should be the same instance type, or at least have the same vCPU and memory resources.
  # see: https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html
  # for_each        = aws_subnet.nodes
  for_each        = { for subnet in aws_subnet.nodes[*] : subnet.id => subnet }
  ami_type        = "AL2_x86_64" # or AL2_x86_64_GPU
  capacity_type   = "SPOT"
  cluster_name    = aws_eks_cluster.current.name
  disk_size       = 50
  instance_types  = ["t3.medium"]
  node_group_name = "${local.name}-normal-${replace(each.value.availability_zone, local.region, "")}"
  node_role_arn   = aws_iam_role.roles["node"].arn
  subnet_ids      = [each.value.id]

  labels = {
    spot   = true
    az     = each.value.availability_zone
    region = local.region
  }

  remote_access {
    ec2_ssh_key = aws_key_pair.current.key_name
  }

  scaling_config {
    desired_size = 1
    max_size     = 3
    min_size     = 0
  }

  tags = {
    Name = "${local.name}-normal-${replace(each.value.availability_zone, local.region, "")}"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling,
  # otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_node_iam_role_attachment,
    aws_iam_role_policy_attachment.control_plane_cluster_policy,
  ]
}

###
### Node permissions
###

# Control plane and node roles
resource "aws_iam_role" "roles" {
  for_each = {
    control-plane : "eks"
    node : "ec2"
  }
  name = "${local.name}-${each.key}"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "${each.value}.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "control_plane_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.roles["control-plane"].name
}

resource "aws_iam_role_policy_attachment" "control_plane_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.roles["control-plane"].name
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.roles["node"].name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.roles["node"].name
}

resource "aws_iam_role_policy_attachment" "node_container_registry_ro" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.roles["node"].name
}

resource "aws_iam_role_policy_attachment" "node_plus_cloudwatch_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.roles["node"].name
}

resource "aws_iam_role_policy_attachment" "cluster_node_iam_role_attachment" {
  policy_arn = aws_iam_policy.cluster_node_policy.arn
  role       = aws_iam_role.roles["node"].name
}

resource "aws_iam_policy" "cluster_node_policy" {
  name   = "${local.name}-node"
  policy = data.aws_iam_policy_document.cluster_node_policy_doc.json
}

data "aws_iam_policy_document" "cluster_node_policy_doc" {
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    # https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md#iam-policy
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeTags", # Allow Cluster Autoscaler to automatically discover EC2 Auto Scaling Groups
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeLaunchTemplateVersions", # (if you created your ASG using a Launch Template)
      # "autoscaling:DescribeLaunchConfigurations", # (if you created your ASG using a Launch Configuration)
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.id}:log-group:/aws/*/${aws_eks_cluster.current.name}/*",
    ]
  }
}
###
### Autoscaling
###

resource "helm_release" "cluster_autoscaler" {
  # https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler
  # https://docs.aws.amazon.com/prescriptive-guidance/latest/containers-provision-eks-clusters-terraform/helm-add-ons.html
  chart            = "cluster-autoscaler"
  create_namespace = true
  name             = "cluster-autoscaler"
  namespace        = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  wait             = false

  set {
    name  = "awsRegion"
    value = local.region
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = aws_eks_cluster.current.name
  }
  provider = helm.demo
}

resource "helm_release" "metrics_server" {
  # https://github.com/kubernetes-sigs/metrics-server/blob/master/charts/metrics-server/README.md
  chart            = "metrics-server"
  create_namespace = true
  name             = "metrics-server"
  namespace        = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  wait             = false

  provider = helm.demo
}
