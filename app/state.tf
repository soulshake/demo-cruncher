terraform {
  backend "s3" {
    bucket  = "ephemerasearch-tfstate-app"
    key     = "tfstate"
    encrypt = true
  }
}
