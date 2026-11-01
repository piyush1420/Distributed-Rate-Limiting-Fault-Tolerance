# ─────────────────────────────────────────────────────────────────────────────
# Raft API tier — stateless ECS Fargate service in front of the Raft cluster.
#
# Each task runs raft-api (src/raft-api/), which maintains a per-task in-memory
# cache and forwards cache misses to the current Raft leader.
#
# Auto-scales 1→10 tasks based on CPU. All /raft/* traffic from the ALB routes
# here first; raft-api then forwards internally to the Raft EC2 cluster.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "raft_api" {
  name                 = "${var.project}/raft-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_cloudwatch_log_group" "raft_api" {
  name              = "/ecs/${var.project}/raft-api"
  retention_in_days = 7
}

# ── Security group ───────────────────────────────────────────────────────────
# raft-api receives traffic from the ALB on port 8000.
# Egress unrestricted so it can reach Raft EC2 instances on 10.0.0.10/11/12:8000.

resource "aws_security_group" "raft_api" {
  name   = "${var.project}-raft-api-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-raft-api-sg" }
}

# ── Task definition ──────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "raft_api" {
  family                   = "${var.project}-raft-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([{
    name  = "raft-api"
    image = "public.ecr.aws/d0v7o8n5/redisvraft-piyush-raft-api:latest"
    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "RAFT_NODES", value = "10.0.0.10:8000,10.0.0.11:8000,10.0.0.12:8000" },
      { name = "CACHE_TTL_SECS", value = "1" },
      { name = "HTTP_ADDR", value = "0.0.0.0:8000" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.raft_api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "raft-api"
      }
    }
  }])
}

# ── Service ──────────────────────────────────────────────────────────────────

resource "aws_ecs_service" "raft_api" {
  name            = "${var.project}-raft-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.raft_api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.raft_api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.raft_api.arn
    container_name   = "raft-api"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http]

  # Auto-scaling will change desired_count at runtime — ignore drift.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── Auto-scaling: 1→10 tasks based on CPU ───────────────────────────────────

resource "aws_appautoscaling_target" "raft_api" {
  max_capacity       = 10
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.raft_api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "raft_api_cpu" {
  name               = "${var.project}-raft-api-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.raft_api.resource_id
  scalable_dimension = aws_appautoscaling_target.raft_api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.raft_api.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 30
  }
}

# ── Target group for raft-api ────────────────────────────────────────────────
# NOTE: target_type = "ip" because Fargate tasks register by IP, not instance ID.
# This is different from the Raft EC2 target group which uses "instance".

resource "aws_lb_target_group" "raft_api" {
  name        = "${var.project}-raft-api-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}