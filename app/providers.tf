terraform {
  required_version = ">= 0.15"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.60.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.1.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###
### aws provider
###
provider "aws" {
  default_tags {
    tags = {
      repo_dir  = basename(abspath(path.root))
      terraform = true
      workspace = terraform.workspace
    }
  }
}

###
### k8s providers
###

data "aws_eks_cluster" "demo" {
  name = "demo"
}

data "aws_eks_cluster_auth" "demo" {
  name = data.aws_eks_cluster.demo.name
}

provider "kubernetes" {
  host = "all-k8s-resources-must-specify-a-provider"
}
provider "kubernetes" {
  alias                  = "demo"
  host                   = data.aws_eks_cluster.demo.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.demo.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.demo.token
}
