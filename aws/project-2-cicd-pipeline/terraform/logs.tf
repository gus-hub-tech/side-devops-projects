# logs.tf - CloudWatch log group used by the awslogs driver

resource "aws_cloudwatch_log_group" "webapp" {
  name = var.log_group_name
}
