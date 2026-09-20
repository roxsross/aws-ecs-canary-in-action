terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state keeps the lab friction free. For team use, switch to S3 + DynamoDB
  # locking (or S3 native locking) by uncommenting and running `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket       = "my-tfstate-bucket"
  #   key          = "canary-lab/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
