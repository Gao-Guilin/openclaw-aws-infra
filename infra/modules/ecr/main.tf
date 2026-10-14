resource "aws_ecr_repository" "this" {
  name                 = "${var.name_prefix}-agent"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = {
    Name = "${var.name_prefix}-agent"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images older than the configured retention period"

        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiration_days
        }

        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Retain only the newest configured number of images"

        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }

        action = {
          type = "expire"
        }
      }
    ]
  })
}
