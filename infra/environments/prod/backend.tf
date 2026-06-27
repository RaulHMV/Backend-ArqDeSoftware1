terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Account ID de Victor (020379956700).
    bucket         = "ticketsys-tfstate-020379956700"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ticketsys-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "ticket-system"
      Environment = "prod"
      ManagedBy   = "Terraform"
    }
  }
}
