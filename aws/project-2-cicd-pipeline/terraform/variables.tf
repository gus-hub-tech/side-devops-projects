# variables.tf - Names and sizing for the existing deployment
#
# Defaults match the values in aws_setup.sh and the live account. Override them
# with a terraform.tfvars file if you deploy a copy under different names.

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "af-south-1"
}

variable "vpc_name" {
  description = "Name tag of the existing shared VPC"
  type        = string
  default     = "projects-vpc"
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
  default     = "webapp-cicd-cluster"
}

variable "service_name" {
  description = "ECS service name"
  type        = string
  default     = "webapp-cicd-service"
}

variable "task_family" {
  description = "ECS task definition family"
  type        = string
  default     = "webapp-cicd-task"
}

variable "ecr_repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "my-webapp"
}

variable "ecr_tagged_image_count" {
  description = "Number of most recent commit-SHA tagged ECR images to keep"
  type        = number
  default     = 1
}

variable "ecr_untagged_image_count" {
  description = "Number of most recent untagged ECR images to keep"
  type        = number
  default     = 1
}

variable "log_group_name" {
  description = "CloudWatch log group used by the container"
  type        = string
  default     = "/ecs/webapp-cicd-task"
}

variable "security_group_name" {
  description = "Security group name for the web app"
  type        = string
  default     = "webapp-cicd-sg"
}

variable "execution_role_name" {
  description = "IAM role ECS uses to pull the image and write logs"
  type        = string
  default     = "ecsTaskExecutionRole-webapp-cicd-cluster"
}

variable "github_actions_user_name" {
  description = "IAM user used by the GitHub Actions deploy job"
  type        = string
  default     = "github-actions-user"
}

variable "container_image_tag" {
  description = "Image tag for the initial task definition. The repository URI is derived from the account, region, and ECR repository name. Defaults to the tag that was live when the stack was adopted; the CI deploy job registers later revisions."
  type        = string
  default     = "8b63159c311665f253285ee6aeb0bc4bc5a75612"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 3001
}

variable "cpu" {
  description = "Fargate task CPU units"
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Fargate task memory in MiB"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of running tasks"
  type        = number
  default     = 1
}

variable "environment" {
  description = "ENVIRONMENT value passed to the container"
  type        = string
  default     = "production"
}
