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
  region              = "eu-central-1"
  allowed_account_ids = [731288958074]
  default_tags {
    tags = {
      repo_dir  = basename(abspath(path.root))
      terraform = true
      workspace = terraform.workspace
    }
  }
  # no assume_role here; credentials are set via environment variables to avoid Terraform+MFA problems
}
