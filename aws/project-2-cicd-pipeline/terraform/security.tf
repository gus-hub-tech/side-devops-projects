# security.tf - Network access for the Fargate task
#
# There is no load balancer in this project, so the task is reached directly on
# port 3001 using its public IP.

resource "aws_security_group" "webapp" {
  name        = var.security_group_name
  description = "Security group for webapp CI/CD"
  vpc_id      = data.aws_vpc.projects.id

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
