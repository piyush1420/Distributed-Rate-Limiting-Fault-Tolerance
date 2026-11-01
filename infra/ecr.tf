resource "aws_ecr_repository" "redis_limiter" {
  name                 = "${var.project}/redis-limiter"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "raft_limiter" {
  name                 = "${var.project}/raft-limiter"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
