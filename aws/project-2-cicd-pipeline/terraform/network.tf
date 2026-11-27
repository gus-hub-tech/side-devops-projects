# network.tf - Existing shared VPC and public subnets
#
# The projects VPC is shared with the other projects in this account. Project 2
# does not create or own it; it looks up the VPC by its Name tag, matching
# aws_setup.sh and project 1.

data "aws_vpc" "projects" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# aws_setup.sh selects subnets tagged "<vpc>-subnet-public*". These public
# subnets are shared by the ALB and by the ECS tasks (which also get public IPs).
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.projects.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.vpc_name}-subnet-public*"]
  }
}
