variable "key_pair_name" {
  description = "Name of the EC2 key pair to use for node access via SSH."
  default     = "demo-aj"
  type        = string
}
locals {
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  aws                = 1
  id                 = data.aws_caller_identity.current.account_id
  labels             = local.tags
  name               = "demo"
  region             = data.aws_region.current.name
  tags               = {}
}

###
### Cluster
###

data "aws_iam_role" "control_plane" {
  name = "demo-control-plane"
}

data "aws_iam_role" "node" {
  name = "demo-node"
}

resource "aws_eks_cluster" "current" {
  name                      = "demo"
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  role_arn                  = one(data.aws_iam_role.control_plane[*].arn)
  version                   = "1.21"
  tags                      = local.tags

  vpc_config {
    security_group_ids = [one(aws_security_group.control_plane[*].id)]
    subnet_ids         = aws_subnet.current.*.id
  }

  depends_on = [aws_cloudwatch_log_group.cluster]
}

data "tls_certificate" "cluster" {
  # Used for obtaining the thumbprints provided to the OIDC provider
  # h/t https://marcincuber.medium.com/amazon-eks-with-oidc-provider-iam-roles-for-kubernetes-services-accounts-59015d15cb0c
  # url = data.aws_eks_cluster.platform.identity.0.oidc.0.issuer
  url = aws_eks_cluster.current.identity.0.oidc.0.issuer
}

resource "aws_iam_openid_connect_provider" "default" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates.0.sha1_fingerprint]
  url             = aws_eks_cluster.current.identity.0.oidc.0.issuer
  tags = merge(local.tags, {
    Name = "${terraform.workspace}-oidc-provider"
  })
}

# aws-auth configMap
resource "kubernetes_config_map" "aws_auth" {
  # Tip: ensure node pools depend on this resource; otherwise it gets automatically created, so our own creation fails.
  depends_on = [aws_eks_cluster.current]

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = <<MAPROLES
- rolearn: ${one(data.aws_iam_role.node[*].arn)}
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
MAPROLES

    mapAccounts = <<MAPACCOUNTS
- "${local.id}"
MAPACCOUNTS
  }
  provider = kubernetes.demo
}

resource "aws_cloudwatch_log_group" "cluster" {
  # Reference: https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 30
}

# Networking
resource "aws_vpc" "current" {
  cidr_block = "10.0.0.0/16"
  tags       = local.tags
}

resource "aws_subnet" "current" {
  count = length(local.availability_zones)

  availability_zone       = local.availability_zones[count.index]
  cidr_block              = "10.0.${count.index * 16}.0/20"
  map_public_ip_on_launch = true
  vpc_id                  = one(aws_vpc.current[*].id)

  tags = merge(local.tags, {
    Name = "${local.name}-${local.availability_zones[count.index]}"
    # https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
    "kubernetes.io/cluster/${local.name}" = "shared"
  })
}

resource "aws_internet_gateway" "current" {
  tags   = local.tags
  vpc_id = one(aws_vpc.current[*].id)
}

resource "aws_route_table" "current" {
  tags   = local.tags
  vpc_id = one(aws_vpc.current[*].id)
}

resource "aws_route" "current" {
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = one(aws_internet_gateway.current[*].id)
  route_table_id         = one(aws_route_table.current[*].id)
}

resource "aws_route_table_association" "current" {
  count = length(local.availability_zones)

  route_table_id = one(aws_route_table.current[*].id)
  subnet_id      = aws_subnet.current[count.index].id
}

resource "aws_security_group" "control_plane" {
  description = "Cluster communication with worker nodes."
  name        = local.name
  tags        = local.tags
  vpc_id      = one(aws_vpc.current[*].id)

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
  security_group_id = one(aws_security_group.control_plane[*].id)
  to_port           = 443
  type              = "ingress"
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

###
### Metrics server
###

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

###
### Node groups
###

# data "aws_iam_role"
resource "aws_eks_node_group" "ng" {
  # all instances in node group should be the same instance type, or at least have the same vCPU and memory resources.
  # see: https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html
  for_each        = { for subnet in aws_subnet.current[*] : subnet.id => subnet }
  ami_type        = "AL2_x86_64" # or AL2_x86_64_GPU
  capacity_type   = "SPOT"
  cluster_name    = aws_eks_cluster.current.name
  disk_size       = 50
  instance_types  = ["t3.medium"]
  node_group_name = "${terraform.workspace}-normal-${replace(each.value.availability_zone, local.region, "")}"
  node_role_arn   = one(data.aws_iam_role.node[*].arn)
  subnet_ids      = [each.value.id]

  labels = merge(local.labels, {
    spot   = true
    az     = each.value.availability_zone
    region = local.region
  })

  remote_access {
    ec2_ssh_key = var.key_pair_name
  }

  scaling_config {
    desired_size = 1
    max_size     = 3
    min_size     = 0
  }

  tags = merge(local.tags, {
    Name = "${terraform.workspace}-normal-${replace(each.value.availability_zone, local.region, "")}"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Force the node group to depend on aws-auth configmap; otherwise it gets created automatically and we have to import it
  # TODO: Also ensure that IAM Role permissions are created before and deleted after EKS Node Group handling,
  # otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [kubernetes_config_map.aws_auth]
}

###
### Node permissions
###
resource "aws_iam_policy" "cluster_node_policy" {
  name   = "demo-node"
  policy = data.aws_iam_policy_document.cluster_node_policy_doc.json
  tags   = local.tags
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

resource "aws_iam_role_policy_attachment" "cluster_node_iam_role_attachment" {
  policy_arn = one(aws_iam_policy.cluster_node_policy[*].arn)
  role       = data.aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_plus_cloudwatch_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = data.aws_iam_role.node.name
}
