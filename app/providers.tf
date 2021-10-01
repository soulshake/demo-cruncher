terraform {
  required_version = ">= 0.15"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.60.0"
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
### k8s auth
###

data "aws_eks_cluster" "demo" {
  name = "demo"
}

data "aws_eks_cluster_auth" "demo" {
  name = data.aws_eks_cluster.demo.name
}
