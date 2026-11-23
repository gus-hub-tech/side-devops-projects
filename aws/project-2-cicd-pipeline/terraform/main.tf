# main.tf - Core settings and the ECS cluster for the CI/CD web app
#
# This configuration adopts the resources created by ../aws_setup.sh. The
# import blocks in imports.tf map the existing AWS resources to the addresses
# below, so the first apply does not recreate or replace the running service.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  # Keep the container/log names consistent with server.js and the setup script.
  container_name = "webapp"
  app_port       = var.container_port
}

resource "aws_ecs_cluster" "main" {
  name = var.cluster_name
}
