# imports.tf - Adopt the resources created by aws_setup.sh
#
# Run `terraform plan` first: these blocks show the existing resources being
# imported instead of created. `terraform apply` records them in state. After
# that, the import blocks are no-ops and can stay in the configuration.
#
# The ECS task definition is imported at the revision that was live when this
# configuration was written. If the CI deploy job has already registered a
# newer revision, update :12 below to the revision Terraform should adopt.

import {
  to = aws_ecr_repository.webapp
  id = var.ecr_repository_name
}

import {
  to = aws_security_group.webapp
  id = "sg-0fceddfefa122f5a2"
}

import {
  to = aws_cloudwatch_log_group.webapp
  id = var.log_group_name
}

import {
  to = aws_iam_role.execution
  id = var.execution_role_name
}

import {
  to = aws_iam_role_policy_attachment.execution
  id = "${var.execution_role_name}/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

import {
  to = aws_ecs_cluster.main
  id = var.cluster_name
}

import {
  to = aws_ecs_task_definition.webapp
  id = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.task_family}:12"
}

import {
  to = aws_ecs_service.webapp
  id = "${var.cluster_name}/${var.service_name}"
}

import {
  to = aws_iam_user.github_actions
  id = var.github_actions_user_name
}

import {
  to = aws_iam_user_policy_attachment.github_ecs
  id = "${var.github_actions_user_name}/arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

import {
  to = aws_iam_user_policy_attachment.github_ecr
  id = "${var.github_actions_user_name}/arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}
