terraform {
  backend "s3" {
    bucket         = "ephemerasearch-tfstate-demo-cluster"
    region         = "eu-central-1"
    key            = "tfstate"
    dynamodb_table = "terraform-state-locks"
    encrypt        = true
  }
}
