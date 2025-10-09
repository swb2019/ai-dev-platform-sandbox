terraform {
  backend "gcs" {
    bucket = "ai-dev-tf-state-474414"
    prefix = "state/prod"
  }
}
