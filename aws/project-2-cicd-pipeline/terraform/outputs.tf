# outputs.tf - Values needed by the deployment workflow and for debugging

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "vpc_id" {
  description = "Shared VPC ID"
  value       = data.aws_vpc.projects.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs used by the ECS service"
  value       = data.aws_subnets.public.ids
}

output "ecr_repository_url" {
  description = "ECR repository URL for docker push"
  value       = aws_ecr_repository.webapp.repository_url
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.webapp.name
}

output "task_definition_arn" {
  description = "Task definition revision managed by Terraform"
  value       = aws_ecs_task_definition.webapp.arn
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.webapp.name
}

output "security_group_id" {
  description = "Web app security group ID"
  value       = aws_security_group.webapp.id
}

output "github_actions_user_name" {
  description = "IAM user whose access key belongs in the GitHub repository secrets"
  value       = aws_iam_user.github_actions.name
}

output "app_url_hint" {
  description = "How to find the app URL after deployment"
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.main.name} --service-name ${aws_ecs_service.webapp.name} --region ${var.aws_region}"
}
