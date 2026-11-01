# ADR 005 — Terraform for AWS infrastructure

**Date:** 2026-04-18  
**Status:** Accepted

## Decision

AWS infrastructure is managed with **Terraform** (`infra/` directory).

## Context

The project needs repeatable, version-controlled infrastructure for two ECS services, ElastiCache, an ALB, Cloud Map, ECR, and VPC networking. An IaC tool is required to avoid snowflake environments that can't be reproduced for benchmarking.

## Alternatives rejected

- **AWS CDK** — good option but adds a Node.js/TypeScript dependency to a Go + Python repo; Terraform is more readable for teammates unfamiliar with CDK.
- **CloudFormation** — verbose YAML; slower iteration cycle than Terraform.
- **Manual console setup** — not reproducible; benchmark environments must be identical between Redis and Raft test runs.

## Consequences

- State is stored in an S3 backend with DynamoDB locking (defined in `infra/main.tf`) — requires a bootstrap step before first `terraform apply`.
- AWS credentials must be configured locally (`aws configure` or env vars) before running Terraform.
- Destroying and recreating the stack is the intended way to reset between benchmark runs.
