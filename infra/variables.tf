variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short name used in resource names and tags"
  type        = string
  default     = "redisvraft"
}

variable "redis_capacity" {
  description = "Token bucket capacity (max tokens per user)"
  type        = number
  default     = 100
}

variable "redis_fill_rate" {
  description = "Token fill rate in tokens/second"
  type        = number
  default     = 1
}

variable "raft_max_tokens" {
  description = "Max tokens per user for Raft limiter"
  type        = number
  default     = 100
}

variable "raft_window_secs" {
  description = "Refill window in seconds for Raft limiter (fill_rate = max_tokens/window_secs)"
  type        = number
  default     = 60
}

variable "raft_heartbeat_ms" {
  description = "Raft heartbeat timeout in milliseconds"
  type        = number
  default     = 500
}

variable "raft_election_ms" {
  description = "Raft election timeout in milliseconds"
  type        = number
  default     = 1000
}
