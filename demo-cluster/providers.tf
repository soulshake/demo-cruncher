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

output "whoami" {
  value = data.aws_caller_identity.current.arn
}

###
### aws provider
###
provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = [731288958074]
  default_tags {
    tags = {
      cluster   = "demo"
      repo_dir  = basename(abspath(path.root))
      terraform = true
      workspace = terraform.workspace
    }
  }
  # no assume_role here; credentials are set via environment variables to avoid Terraform+MFA problems
}

###
### k8s providers
###

provider "kubernetes" {
  host = "all-k8s-resources-must-specify-a-provider"
}
provider "kubernetes" {
  alias                  = "demo"
  host                   = aws_eks_cluster.current.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.current.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.current.token
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
