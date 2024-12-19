terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.82.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
  }
}
