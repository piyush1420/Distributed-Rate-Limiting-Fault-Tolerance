# ADR 001 — Unified API contract across both limiters

**Date:** 2026-04-18  
**Status:** Accepted

## Decision

Both the Redis and Raft rate limiters expose the same HTTP API:

```
GET /check?user=<id>   → 200 (allowed) | 429 (rate limited)
GET /health            → 200 always (ALB health check)
GET /status            → 200 with backend/cluster info
```

## Context

The Redis limiter was originally built with `POST /allow` + JSON body. The Raft limiter was built independently with `GET /check?user=`. When merging both into a unified repo, a single Locust harness could not target both without branching on the backend type.

## Alternatives rejected

- **Keep both APIs, branch in Locust** — harness complexity grows with each new limiter added; error-prone.
- **Adopt POST for both** — GET is more natural for a read-like "am I allowed?" check and avoids body parsing overhead at high RPS.

## Consequences

- The Locust harness in `experiments/locustfile.py` works against either limiter with zero changes — just point `--host` at the right ALB target group.
- Any future limiter implementation must adopt this contract before it can be benchmarked.
