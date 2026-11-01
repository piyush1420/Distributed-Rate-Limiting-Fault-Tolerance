resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "redis_limiter" {
  name              = "/ecs/${var.project}/redis-limiter"
  retention_in_days = 7
}

# ── Redis limiter (Fargate — stateless, no peer discovery needed) ─────────────

resource "aws_ecs_task_definition" "redis_limiter" {
  family                   = "${var.project}-redis-limiter"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([{
    name  = "redis-limiter"
    image = "public.ecr.aws/d0v7o8n5/redisvraft-piyush-redis-limiter:latest"
    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "REDIS_ADDR", value = "${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379" },
      { name = "CAPACITY", value = tostring(var.redis_capacity) },
      { name = "FILL_RATE", value = tostring(var.redis_fill_rate) },
      { name = "HTTP_ADDR", value = "0.0.0.0:8000" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.redis_limiter.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "redis-limiter"
      }
    }
  }])
}

resource "aws_ecs_service" "redis_limiter" {
  name            = "${var.project}-redis-limiter"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.redis_limiter.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.redis_limiter.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.redis_limiter.arn
    container_name   = "redis-limiter"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http]
}
