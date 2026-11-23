# ecr.tf - Container image repository
#
# GitHub Actions pushes both the commit SHA and latest tags here.

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
