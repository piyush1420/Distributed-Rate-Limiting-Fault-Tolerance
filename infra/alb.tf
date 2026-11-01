resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-alb" }
}

# ── Redis target group ────────────────────────────────────────────────────────

resource "aws_lb_target_group" "redis_limiter" {
  name        = "${var.project}-redis-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate

  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ── Raft target group (all 3 nodes) ──────────────────────────────────────────
# Followers return 307 with leader address; the Locust client follows redirects
# automatically, so routing any node is fine.

resource "aws_lb_target_group" "raft_limiter" {
  name        = "${var.project}-raft-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance" # EC2 instances registered via target_group_attachment

  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ── Listener with path-based routing ─────────────────────────────────────────
# /redis/* → redis-limiter
# /raft/*  → raft-limiter
# Strip the prefix in the app — or use separate ALBs for cleaner separation.

# Single port 80 listener with path-based routing:
#   /raft/* → raft-limiter target group  (Locust: --host http://<alb>/raft)
#   default → redis-limiter target group (Locust: --host http://<alb>)
#
# The Raft app registers routes under both / and /raft/ prefixes (handlers.go),
# so the full forwarded path /raft/check is handled correctly.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.redis_limiter.arn
  }
}

resource "aws_lb_listener_rule" "raft" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/raft/*"]
    }
  }

  action {
    type             = "forward"
#   target_group_arn = aws_lb_target_group.raft_api.arn # for the approximate rate limiting(caching layer)
    target_group_arn = aws_lb_target_group.raft_limiter.arn
  }
}
