"""
20_locust_steady_raft_cached.py

Steady-state load test for the Raft rate limiter WITH raft-api cache layer.
Matches test parameters (200 users, 120s, 20 users/sec ramp,
80/10/10 task mix) so the results are directly comparable.

The key difference: test hit raw Raft nodes via ALB (/check).
This test hits the raft-api caching layer via ALB (/raft/check).
Cache absorbs repeat requests, so we expect higher throughput and lower
latency than  raw Raft numbers (1,180 req/s, 67ms median).

Run (steady 200 users, matches ):
    cd ~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency
    locust -f experiments/20_locust_steady_raft_cached.py \
        --host http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com \
        --users 200 \
        --spawn-rate 20 \
        --run-time 120s \
        --headless \
        --csv results/raft_cached_steady_$(date +%s) \
        --html results/raft_cached_steady_$(date +%s).html

Compare against Redis baseline:
    Redis:     1,990 req/s | 38ms median | 79ms p95 | 140ms p99
    Raw Raft:  1,180 req/s | 67ms median | 170ms p95 | 240ms p99
"""

import random
from locust import HttpUser, task, between


class RaftCachedUser(HttpUser):
    """Simulates a pool of 1,000 distinct users hitting the cached Raft path."""

    wait_time = between(0.01, 0.05)

    def on_start(self):
        self.user_id = f"user-{random.randint(1, 1000)}"

    @task(8)
    def check_rate_limit(self):
        """Core benchmark task — measures /raft/check latency and 429 rate."""
        with self.client.get(
            f"/raft/check?user={self.user_id}",
            name="/raft/check",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            elif resp.status_code == 429:
                resp.success()
                self.environment.events.request.fire(
                    request_type="GET",
                    name="/raft/check [429]",
                    response_time=resp.elapsed.total_seconds() * 1000,
                    response_length=len(resp.content),
                    exception=None,
                    context={},
                )
            else:
                resp.failure(f"unexpected status {resp.status_code}")

    @task(1)
    def health(self):
        self.client.get("/raft/health", name="/raft/health")

    @task(1)
    def status(self):
        self.client.get("/raft/status", name="/raft/status")