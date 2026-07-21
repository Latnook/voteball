terraform {
  # 1.11 floor: backend.tf uses S3-native locking (use_lockfile), not the deprecated dynamodb_table.
  required_version = ">= 1.11.0"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = var.region
}
