# security.tf - Network access for the ALB and the Fargate task
#
# The same security group is attached to the internet-facing ALB and to the
# ECS tasks: port 80 serves the stable app URL through the ALB, while port 3001
# is kept open so the task can also be reached directly by its public IP.

resource "aws_security_group" "webapp" {
  name        = var.security_group_name
  description = "Security group for webapp CI/CD"
  vpc_id      = data.aws_vpc.projects.id

  ingress {
    from_port   = var.alb_port
    to_port     = var.alb_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.security_group_name
  }
}
