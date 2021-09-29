terraform {
  backend "s3" {
    bucket  = "ephemerasearch-tfstate-demo-cluster"
    key     = "tfstate"
    encrypt = true
  }
}
