data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project}-vpc" }
}

# Two public subnets across two AZs (ALB requires >= 2)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name   = "${var.project}-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere (Locust driver)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-alb-sg" }
}

resource "aws_security_group" "redis_limiter" {
  name   = "${var.project}-redis-limiter-sg"
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
  tags = { Name = "${var.project}-redis-limiter-sg" }
}

resource "aws_security_group" "elasticache" {
  name   = "${var.project}-elasticache-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Redis from redis-limiter tasks only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.redis_limiter.id]
  }
  tags = { Name = "${var.project}-elasticache-sg" }
}

resource "aws_security_group" "raft" {
  name   = "${var.project}-raft-sg"
  vpc_id = aws_vpc.main.id

  
    # in the below change  
    #"HTTP from raft-api ECS tasks only" for cache layer approximate rate limiting
    # security_groups = [aws_security_group.raft_api.id]
  ingress {
    description     = "HTTP from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description = "Raft peer traffic (TCP 7000) - nodes talk to each other"
    from_port   = 7000
    to_port     = 7000
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description = "Raft HTTP join (TCP 8000) - node2/3 POST /join to leader"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "SSH from my laptop for chaos experiments"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-raft-sg" }
}
