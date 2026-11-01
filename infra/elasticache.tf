resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache-subnet"
  subnet_ids = aws_subnet.public[*].id
}

# Single-node Redis — cluster mode not needed because atomicity is handled
# by the Lua script inside Redis, not by Redis Cluster sharding.
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.elasticache.id]

  tags = { Name = "${var.project}-redis" }
}
