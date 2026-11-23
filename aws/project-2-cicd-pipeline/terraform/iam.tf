# iam.tf - Task execution role and the GitHub Actions deployment user

resource "aws_iam_role" "execution" {
  name = var.execution_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The workflow uses this user's access key, which is stored in GitHub repository
# secrets. Access keys are intentionally not managed here: the secret value is
# only returned once at creation time, so Terraform cannot import the existing
# key without replacing it. Rotate keys manually and update the GitHub secrets.
resource "aws_iam_user" "github_actions" {
  name          = var.github_actions_user_name
  force_destroy = true
}

resource "aws_iam_user_policy_attachment" "github_ecs" {
  user       = aws_iam_user.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

resource "aws_iam_user_policy_attachment" "github_ecr" {
  user       = aws_iam_user.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}
