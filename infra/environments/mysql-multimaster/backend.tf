terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Mismo bucket y tabla de lock que crea infra/bootstrap; solo cambia la key,
  # asi este stack tiene su propio state, independiente de prod y de Postgres.
  backend "s3" {
    bucket         = "ticketsys-tfstate-020379956700"
    key            = "mysql-multimaster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ticketsys-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "ticket-system"
      Stack     = "mysql-multimaster"
      ManagedBy = "Terraform"
    }
  }
}
