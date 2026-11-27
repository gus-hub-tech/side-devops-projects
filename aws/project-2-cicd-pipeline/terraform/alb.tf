# alb.tf - Internet-facing ALB and its single target group
#
# The ALB is intentionally disposable: it is deleted and recreated regularly,
# so these resources are identified only by the stable names in variables.tf.
# Nothing here depends on ALB ARNs or DNS names, which change on recreation.
# The ECS service registers task IPs in this target group (see ecs.tf). AWS
# allocates the two Elastic IPs (webapp-cicd-loadbalancer-az1 / -az2) itself;
# they are not separate aws_eip resources and come back with the ALB.

resource "aws_lb" "webapp" {
  name               = var.alb_name
  internal           = false
  load_balancer_type = "application"

  # The ALB shares the webapp security group. Port 80 is opened to the world in
  # security.tf; port 3001 stays open so tasks can also be reached directly.
  security_groups = [aws_security_group.webapp.id]
  subnets         = data.aws_subnets.public.ids

  ip_address_type                  = "ipv4"
  idle_timeout                     = 60
  enable_http2                     = true
  enable_cross_zone_load_balancing = true

  # Matches the live load balancer, which has deletion protection disabled.
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "webapp" {
  name        = var.target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.projects.id
  target_type = "ip"

  deregistration_delay = 300

  health_check {
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "webapp" {
  load_balancer_arn = aws_lb.webapp.arn
  port              = var.alb_port
  protocol          = "HTTP"

  # The live listener has one weighted target group with stickiness disabled.
  # Spell that out so importing it does not trigger a needless update.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webapp.arn

    forward {
      target_group {
        arn    = aws_lb_target_group.webapp.arn
        weight = 1
      }

      stickiness {
        enabled  = false
        duration = 3600
      }
    }
  }
}
