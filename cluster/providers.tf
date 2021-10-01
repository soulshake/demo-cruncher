terraform {
  required_version = ">= 0.15"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.60.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.3.0"
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
provider "aws" {}

###
### k8s providers
###

data "aws_eks_cluster_auth" "current" {
  name = aws_eks_cluster.current.name
}

provider "helm" {
  # Placeholder to ensure all helm resources have an explicit provider as well.
  kubernetes {
    host = "all-helm-resources-must-have-a-provider"
  }
}

provider "helm" {
  alias = "demo"
  kubernetes {
    host                   = aws_eks_cluster.current.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.current.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.current.token
  }
}
