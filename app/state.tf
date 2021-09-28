terraform {
  backend "s3" {
    bucket         = "ephemerasearch-tfstate-app"
    region         = "eu-central-1"
    key            = "tfstate"
    dynamodb_table = "terraform-state-locks"
    encrypt        = true
  }
}
