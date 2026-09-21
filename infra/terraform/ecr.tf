# The default flow creates the repository from scripts/build-push.sh. Flip
# create_ecr_repository to true if you'd rather Terraform owned it.

resource "aws_ecr_repository" "app" {
  count = var.create_ecr_repository ? 1 : 0

  name = local.ecr_repository_name
  #trivy:ignore:AWS-0031 lab convenience: build-push.sh re-tags v1/v2 across repeated demo runs, immutable tags would break re-running the same tag.
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = local.ecr_repository_name }
}

resource "aws_ecr_lifecycle_policy" "app" {
  count = var.create_ecr_repository ? 1 : 0

  repository = aws_ecr_repository.app[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 20 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      },
    ]
  })
}
