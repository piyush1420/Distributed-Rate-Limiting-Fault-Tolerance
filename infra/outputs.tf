output "alb_dns" {
  description = "Point Locust --host at this URL"
  value       = "http://${aws_lb.main.dns_name}"
}

output "redis_limiter_url" {
  description = "Locust --host for Redis benchmark"
  value       = "http://${aws_lb.main.dns_name}"
}

output "raft_limiter_url" {
  description = "Locust --host for Raft benchmark"
  value       = "http://${aws_lb.main.dns_name}/raft"
}

output "ecr_redis_limiter" {
  description = "ECR repo URL for redis-limiter — use in docker push"
  value       = aws_ecr_repository.redis_limiter.repository_url
}

output "ecr_raft_limiter" {
  description = "ECR repo URL for raft-limiter — use in docker push"
  value       = aws_ecr_repository.raft_limiter.repository_url
}

output "ecr_raft_api" {
  description = "ECR repo URL for raft-api — use in docker push"
  value       = aws_ecr_repository.raft_api.repository_url
}
output "elasticache_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}
