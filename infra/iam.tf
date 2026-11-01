# ─────────────────────────────────────────────────────────────────────────────
# IAM for Innovation Sandbox accounts.
#
# Unlike AWS Academy Learner Lab (which has a pre-existing "LabRole"),
# Innovation Sandbox accounts require us to create roles from scratch.
#
# This file creates two roles with AWS-managed policies attached:
#   1. ec2_raft_role     - for the Raft EC2 instances (ECR pull + CloudWatch logs)
#   2. ecs_task_role     - for the ECS Fargate services (redis-limiter, raft-api)
#
# The rest of the Terraform files reference `data.aws_iam_role.lab_role` — we
# use a local variable to point that name at whichever role exists.
# ─────────────────────────────────────────────────────────────────────────────

# ── EC2 role for Raft instances ──────────────────────────────────────────────

resource "aws_iam_role" "ec2_raft" {
  name = "${var.project}-ec2-raft-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# ECR read-only so EC2 user-data can docker pull
resource "aws_iam_role_policy_attachment" "ec2_ecr_readonly" {
  role       = aws_iam_role.ec2_raft.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# CloudWatch logs write
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_logs" {
  role       = aws_iam_role.ec2_raft.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# SSM access for debugging via Session Manager (handy if anything breaks)
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_raft.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── ECS task execution role ─────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Standard AWS-managed policy: ECR pull + CloudWatch logs for ECS tasks
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Compatibility shim ──────────────────────────────────────────────────────
# The rest of the Terraform (ecs.tf, raft_ec2.tf) references
#   data.aws_iam_role.lab_role
# We map that data source to our ECS execution role so the other files work
# unchanged. The EC2 instance profile uses aws_iam_role.ec2_raft directly
# (see below — it overrides raft_ec2.tf's default).

data "aws_iam_role" "lab_role" {
  name       = aws_iam_role.ecs_task_execution.name
  depends_on = [aws_iam_role.ecs_task_execution]
}
