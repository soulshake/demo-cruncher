terraform {
  backend "s3" {
    bucket  = "ephemerasearch-tfstate-infra"
    key     = "tfstate"
    encrypt = true
  }
}
