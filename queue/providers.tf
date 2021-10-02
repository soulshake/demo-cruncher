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

provider "aws" {}

###
### k8s auth
###

data "aws_eks_cluster" "current" {
  name = var.cluster
}

data "aws_eks_cluster_auth" "current" {
  name = data.aws_eks_cluster.current.name
}
