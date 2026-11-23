# ecr.tf - Container image repository
#
# GitHub Actions pushes one commit-SHA tag here; no mutable latest tag.

resource "aws_ecr_repository" "webapp" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  # Matches the README cleanup step (`delete-repository --force`): Terraform
  # can remove the repository even though it contains images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "webapp" {
  repository = aws_ecr_repository.webapp.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the ${var.ecr_tagged_image_count} most recent tagged image${var.ecr_tagged_image_count == 1 ? "" : "s"}"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.ecr_tagged_image_count
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.ecr_untagged_image_count} most recent untagged image${var.ecr_untagged_image_count == 1 ? "" : "s"}"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_untagged_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
