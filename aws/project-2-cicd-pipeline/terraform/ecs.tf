# ecs.tf - Task definition and Fargate service
#
# The task definition is imported at its current revision. After adoption the
# GitHub Actions deploy job continues to register new revisions and point the
# service at them, so the service ignores task_definition changes. Terraform
# still owns the service, networking, desired count, and deployment settings.

resource "aws_ecs_task_definition" "webapp" {
  family                   = var.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = local.container_image
      essential = true
      cpu       = 0

      portMappings = [
        {
          containerPort = local.app_port
          hostPort      = local.app_port
          protocol      = "tcp"
          name          = "${local.container_name}-${local.app_port}-tcp"
        }
      ]

      environment = [
        {
          name  = "ENVIRONMENT"
          value = var.environment
        }
      ]

      mountPoints    = []
      volumesFrom    = []
      systemControls = []

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.webapp.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  lifecycle {
    # CI owns task definition revisions; do not re-register the imported one.
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "webapp" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.webapp.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # The service registers each task's IP in the ALB target group. Without this
  # block a Terraform apply would detach the live target group from the service.
  load_balancer {
    target_group_arn = aws_lb_target_group.webapp.arn
    container_name   = local.container_name
    container_port   = local.app_port
  }

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.webapp.id]
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # The existing service has ECS availability zone rebalancing enabled.
  # The provider defaults it to DISABLED, so pin it explicitly.
  availability_zone_rebalancing = "ENABLED"

  lifecycle {
    # The CI deploy job owns task definition revisions, and Application Auto
    # Scaling owns desired_count. Without this, every apply would reset the
    # count the scaler just changed.
    ignore_changes = [task_definition, desired_count]
  }
}
