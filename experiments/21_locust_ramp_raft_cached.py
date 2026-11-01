"""
21_locust_ramp_raft_cached.py

Ramping load test for cached Raft system. Starts at 100 users,
ramps to 2000 users over 10 minutes to trigger ECS auto-scaling.

Run alongside 21_ecs_task_monitor.sh to capture task count over time.

Run:
    cd ~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency

    # Terminal 1 (this test):
    TS=$(date +%s)
    locust -f experiments/21_locust_ramp_raft_cached.py \\
        --host http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com \\
        --users 2000 \\
        --spawn-rate 10 \\
        --run-time 600s \\
        --headless \\
        --csv results/raft_cached_ramp_$TS \\
        --html results/raft_cached_ramp_$TS.html

    # Terminal 2 (task monitor):
    ./experiments/21_ecs_task_monitor.sh

What to expect:
    0-2 min:   100-200 users, 1 raft-api task, low latency
    2-5 min:   200-600 users, ECS scales to 2-3 tasks
    5-8 min:   600-1200 users, ECS scales to 5-7 tasks
    8-10 min:  1200-2000 users, ECS scales to 8-10 tasks (max)
"""

import random
from locust import HttpUser, task, between


USER_POOL = [f"user-{i}" for i in range(1000)]


class RaftCachedRampUser(HttpUser):
    """
    Same task mix as steady test (80/10/10).
    wait_time is slightly longer to allow realistic ramp behavior.
    """

    wait_time = between(0.05, 0.1)

    def on_start(self):
        self.user_id = random.choice(USER_POOL)

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