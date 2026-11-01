# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Benchmarks two approaches to distributed rate limiting — a **Redis-backed continuous token bucket** vs a **Raft consensus token bucket** — under identical load using Locust. Goal: measure throughput, latency, and consistency trade-offs between a single-master shared store vs replicated state machine.

## Architecture

```
docker-compose.yml (unified)
├── src/redis-limiter/   — Go HTTP API, token bucket via atomic Redis Lua script
├── src/raft-limiter/    — Go HTTP API, token bucket replicated via hashicorp/raft (3 nodes)
├── experiments/         — Unified Locust harness (targets either limiter)
├── redis/               — Original standalone Redis prototype (kept for reference)
└── locust/              — Original locustfile for redis/ prototype (kept for reference)
```

### Unified API contract (both limiters)

Both services expose the same endpoints so the Locust harness targets either one without modification:

| Method | Path | Description |
|---|---|---|
| `GET` | `/check?user=<id>` | Rate limit check → 200 allowed, 429 limited |
| `GET` | `/health` | ALB health check |
| `GET` | `/status` | Backend/cluster info |

### Token bucket algorithm (both limiters)

Both use **continuous refill**: `tokens = min(capacity, tokens + elapsed_seconds × fill_rate)`. The Redis version executes this atomically in Lua; the Raft version executes it inside `FSM.Apply()` after majority commit.

### Raft cluster topology

3-node cluster (node1=bootstrap, node2+3 join via node1). All writes go to the leader (`/check` returns 307 with leader address if hit on a follower). Raft transport on port 7000, HTTP on port 8000 per node.

## Commands

### Run full stack (both limiters + Locust)
```bash
docker compose up --build
```
- Redis limiter: `http://localhost:8000`
- Raft node1/2/3: `http://localhost:8001`, `8002`, `8003`
- Locust web UI: `http://localhost:8089` (targets redis-limiter by default)

### Switch Locust to target Raft
```bash
HOST=http://raft-node1:8000 docker compose up locust
```

### Run headless benchmark
```bash
docker compose run --rm locust \
  -f /mnt/locust/locustfile.py \
  --host http://redis-limiter:8000 \
  --headless -u 200 -r 20 --run-time 120s \
  --html /mnt/locust/results/run.html
```

### Build/test individual services
```bash
cd src/redis-limiter && go build ./... && go test ./...
cd src/raft-limiter  && go build ./... && go test ./...
```

### Rebuild a single service
```bash
docker compose up --build redis-limiter
docker compose up --build raft-node1 raft-node2 raft-node3
```

## Configuration

### Redis limiter env vars

| Variable | Default | Meaning |
|---|---|---|
| `REDIS_ADDR` | `localhost:6379` | Redis address |
| `CAPACITY` | `100` | Max tokens per bucket |
| `FILL_RATE` | `1` | Tokens per second |
| `HTTP_ADDR` | `0.0.0.0:8000` | Listen address |

### Raft limiter env vars

| Variable | Default | Meaning |
|---|---|---|
| `NODE_ID` | required | Unique node name |
| `RAFT_ADDR` | `localhost:7000` | Raft peer address |
| `HTTP_ADDR` | `localhost:8000` | HTTP listen address |
| `BOOTSTRAP` | `false` | Set `true` on first node only |
| `JOIN_ADDR` | — | Leader HTTP addr for non-bootstrap nodes |
| `MAX_TOKENS` | `100` | Max tokens per bucket |
| `WINDOW_SECS` | `60` | Refill window (converted to fill_rate = MAX_TOKENS/WINDOW_SECS tokens/sec) |
| `HEARTBEAT_MS` | `1000` | Raft heartbeat timeout |
| `ELECTION_MS` | `1000` | Raft election timeout |

## Load Test Behavior

`experiments/locustfile.py` simulates 1 000 distinct users. Task weights: `/check` (8×), `/health` (1×), `/status` (1×). HTTP 429 responses are counted as Locust successes but also fired as a separate `/check [429]` event so they appear as their own row in the stats table.

## AWS Infrastructure

Terraform lives in `infra/`. One-time bootstrap before first apply:

```bash
aws s3 mb s3://redisvraft-tfstate --region us-east-1
aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

cd infra && terraform init && terraform apply
```

Build and push images after `terraform apply` (ECR repos must exist first):

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
docker build -t $(terraform output -raw ecr_redis_limiter):latest ../src/redis-limiter && docker push ...
docker build -t $(terraform output -raw ecr_raft_limiter):latest  ../src/raft-limiter  && docker push ...
```

## Decisions

All significant design decisions are recorded in `decisions/` as ADRs. Check there before changing API shape, algorithm behavior, or infrastructure approach.

## Results

HTML Locust reports are stored in `results/`. The `Report/` directory contains the milestone report (`milestone1_report.docx`) and architecture diagram.
