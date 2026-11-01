"""
08_load_test_steady.py

Steady-state load test for RAW Raft (no cache layer).
ALB routes directly to 3 Raft EC2 nodes.
Matches Gautam's Redis test parameters for direct comparison.

Parameters:
    Users: 200
    Spawn rate: 20/sec
    Duration: 120s
    Task mix: 80% /raft/check, 10% /raft/health, 10% /raft/status

Run:
    cd ~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency
    TS=$(date +%s)
    locust -f experimentsF/08_load_test_steady.py \
        --host http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com \
        --users 200 \
        --spawn-rate 20 \
        --run-time 120s \
        --headless \
        --csv resultsF/08_load_test_steady/raw_raft_steady_$TS \
        --html resultsF/08_load_test_steady/raw_raft_steady_$TS.html

Compare against:
    Gautam's Redis:      1,990 req/s | 38ms median | 79ms p95
    Gautam's Raw Raft:   1,180 req/s | 67ms median | 170ms p95
"""

import random
from locust import HttpUser, task, between


class RawRaftUser(HttpUser):
    """
    Hits Raft EC2 nodes directly through ALB.
    No cache. Every /raft/check request goes through full Raft consensus.
    """

    wait_time = between(0.01, 0.05)

    def on_start(self):
        self.user_id = f"user-{random.randint(1, 1000)}"

    @task(8)
    def check_rate_limit(self):
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