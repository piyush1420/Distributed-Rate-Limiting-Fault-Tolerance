"""
09_load_test_ramp.py
Ramping load test for RAW Raft. Ramps to 1000 users, 5 min total.
"""
import random
from locust import HttpUser, task, between

class RawRaftRampUser(HttpUser):
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
