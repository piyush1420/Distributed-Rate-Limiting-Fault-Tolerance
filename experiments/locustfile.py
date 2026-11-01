"""
Unified benchmark harness for Redis vs Raft rate limiter comparison.

Both limiters expose the same API contract:
  GET /check?user=<id>   → 200 (allowed) or 429 (rate limited)
  GET /health            → 200 always
  GET /status            → 200 with backend info

Usage
-----
Local Docker (Redis limiter):
  locust -f locustfile.py --host=http://localhost:8000

Local Docker (Raft cluster — hits node1):
  locust -f locustfile.py --host=http://localhost:8001

AWS ALB (either target group):
  locust -f locustfile.py --host=http://<ALB-DNS>

Headless (CI / scripted experiments):
  locust -f locustfile.py --host=http://<host> \\
         --headless -u 200 -r 20 --run-time 120s \\
         --html results/run-$(date +%s).html
"""

import random
from locust import HttpUser, task, between


class RateLimiterUser(HttpUser):
    """Simulates a pool of 1 000 distinct users hammering the /check endpoint."""

    wait_time = between(0.01, 0.05)

    def on_start(self):
        self.user_id = f"user-{random.randint(1, 1000)}"

    @task(8)
    def check_rate_limit(self):
        """Core benchmark task — measures /check latency and 429 rate."""
        with self.client.get(
            f"/check?user={self.user_id}",
            name="/check",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            elif resp.status_code == 429:
                # 429 is an expected, valid response — count it as success
                # so Locust doesn't inflate the failure rate.
                resp.success()
                # Fire a separate event so 429s are visible as their own series
                # in the Locust stats table.
                self.environment.events.request.fire(
                    request_type="GET",
                    name="/check [429]",
                    response_time=resp.elapsed.total_seconds() * 1000,
                    response_length=len(resp.content),
                    exception=None,
                    context={},
                )
            else:
                resp.failure(f"unexpected status {resp.status_code}")

    @task(1)
    def health(self):
        """Keeps the ALB health-check path warm; also gives us baseline latency."""
        self.client.get("/health", name="/health")

    @task(1)
    def status(self):
        """Occasionally sample cluster/backend status."""
        self.client.get("/status", name="/status")