"""
03_redis_failure.py
Kills the Redis ECS task while Locust load is running.
Proves Redis is a single point of failure — no election, no recovery.
Observation window: exactly 60s from kill event.
"""

import glob, json, os, random, time, sys, subprocess, gevent
from locust import HttpUser, task, between
from locust.env import Environment
from locust.stats import stats_printer, stats_history, StatsCSVFileWriter
from locust.html import get_html_report
from locust.log import setup_logging

setup_logging("INFO")

ALB = "http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com"
RESULTS_DIR = os.path.expanduser("~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency/resultsF/03_redis_failure")
OBSERVATION_WINDOW = 60
CLUSTER = "redisvraft-cluster"
SERVICE = "redisvraft-redis-limiter"
REGION = "us-east-1"


def aws_cmd(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return result.stdout.strip()


def get_redis_task_arn():
    raw = aws_cmd(["aws", "ecs", "list-tasks",
        "--cluster", CLUSTER, "--service-name", SERVICE,
        "--region", REGION, "--output", "json"])
    data = json.loads(raw)
    arns = data.get("taskArns", [])
    if not arns:
        print("  ERROR: No Redis ECS tasks found")
        sys.exit(1)
    return arns[0]


class RedisUser(HttpUser):
    host = ALB
    wait_time = between(0.01, 0.05)
    def on_start(self):
        self.user_id = f"user-{random.randint(1, 1000)}"
    @task(8)
    def check_rate_limit(self):
        with self.client.get(f"/check?user={self.user_id}", name="/check", catch_response=True) as resp:
            if resp.status_code in (200, 429):
                resp.success()
            else:
                resp.failure(f"status {resp.status_code}")
    @task(1)
    def health(self):
        self.client.get("/health", name="/health")
    @task(1)
    def status(self):
        self.client.get("/status", name="/status")


def main():
    for f in glob.glob(f"{RESULTS_DIR}/*"):
        os.remove(f)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    ts = int(time.time())
    csv_prefix = f"{RESULTS_DIR}/redis_failure_{ts}"
    html_path = f"{RESULTS_DIR}/redis_failure_{ts}.html"

    print("=" * 60)
    print("EXPERIMENT 03: REDIS FAILURE UNDER LOAD")
    print(f"Observation window: {OBSERVATION_WINDOW}s from kill event")
    print("=" * 60)

    # Step 1: Find Redis ECS task
    print("\nStep 1: Finding Redis ECS task...")
    task_arn = get_redis_task_arn()
    print(f"  Task ARN: {task_arn}")

    # Verify Redis is healthy
    print("  Verifying Redis is responding...")
    result = subprocess.run(["curl", "-s", "-w", "%{http_code}", f"{ALB}/check?user=healthtest"],
        capture_output=True, text=True, timeout=10)
    print(f"  Response: {result.stdout}")

    # Step 2: Start Locust
    print("\nStep 2: Starting Locust (200 users on Redis path)...")
    env = Environment(user_classes=[RedisUser])
    csv_writer = StatsCSVFileWriter(env, [0.5, 0.95, 0.99], csv_prefix, True)
    env.create_local_runner()
    gevent.spawn(stats_printer(env.stats))
    gevent.spawn(stats_history, env.runner)
    gevent.spawn(csv_writer.stats_writer)
    env.runner.start(200, spawn_rate=20)
    print("  Warming up 30s...")
    gevent.sleep(30)

    pre_reqs = env.stats.total.num_requests
    pre_fails = env.stats.total.num_failures
    print(f"  Pre-kill: {pre_reqs} requests, {pre_fails} failures")

    # Step 3: Kill Redis ECS task
    print(f"\nStep 3: Stopping Redis ECS task...")
    kill_time = time.time()
    aws_cmd(["aws", "ecs", "stop-task",
        "--cluster", CLUSTER, "--task", task_arn,
        "--reason", "Fault tolerance experiment",
        "--region", REGION])
    print(f"  Stop command sent at {time.strftime('%H:%M:%S')}")

    # Step 4: Observation window — exactly 60s
    print(f"\nStep 4: Observing for {OBSERVATION_WINDOW}s...")
    gevent.sleep(OBSERVATION_WINDOW)

    obs_reqs = env.stats.total.num_requests - pre_reqs
    obs_fails = env.stats.total.num_failures - pre_fails
    obs_success = ((obs_reqs - obs_fails) / obs_reqs * 100) if obs_reqs > 0 else 0
    print(f"  Observation window results:")
    print(f"    Requests:  {obs_reqs}")
    print(f"    Failures:  {obs_fails}")
    print(f"    Success:   {obs_success:.2f}%")

    # Step 5: Wait for ECS to restart the task automatically
    print("\nStep 5: Waiting for ECS to restart Redis task...")
    recovered = False
    for attempt in range(30):
        try:
            new_arn = get_redis_task_arn()
            if new_arn != task_arn:
                recovery_time = time.time() - kill_time
                print(f"  New task detected: {new_arn}")
                print(f"  ECS restart time: {recovery_time:.1f}s")
                recovered = True
                break
        except Exception:
            pass
        gevent.sleep(5)

    if not recovered:
        recovery_time = time.time() - kill_time
        print(f"  WARNING: No new task after {recovery_time:.1f}s")

    # Wait extra for the new task to become healthy
    print("  Waiting 30s for new task to register with ALB...")
    gevent.sleep(30)

    # Step 6: Verify Redis is back
    print("\nStep 6: Verifying Redis recovery...")
    verify_result = subprocess.run(["curl", "-s", "-w", "\nHTTP %{http_code}", f"{ALB}/check?user=recoverytest"],
        capture_output=True, text=True, timeout=10)
    print(f"  {verify_result.stdout}")

    # Stop Locust
    print("\nStopping Locust...")
    env.runner.quit()
    time.sleep(10)

    total_reqs = env.stats.total.num_requests
    total_fails = env.stats.total.num_failures

    # HTML
    try:
        html = get_html_report(env)
        with open(html_path, "w") as f:
            f.write(html)
        print(f"\n  HTML report: {html_path}")
    except Exception as e:
        print(f"\n  HTML failed: {e}")

    # Summary
    summary = {
        "experiment": "03_redis_failure",
        "system": "Redis (single node, no replication)",
        "task_killed": task_arn,
        "observation_window_s": OBSERVATION_WINDOW,
        "obs_requests": obs_reqs,
        "obs_failures": obs_fails,
        "obs_success_rate": f"{obs_success:.2f}%",
        "total_requests": total_reqs,
        "total_failures": total_fails,
        "ecs_restart_time_s": f"{recovery_time:.1f}",
        "recovery_mechanism": "None — ECS eventually restarts task but no automatic failover",
        "election": "N/A — Redis has no consensus or election mechanism",
        "html_report": html_path,
    }

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for k, v in summary.items():
        print(f"  {k}: {v}")
    print("=" * 60)

    with open(f"{RESULTS_DIR}/summary.txt", "w") as sf:
        for k, v in summary.items():
            sf.write(f"{k}: {v}\n")
    print(f"  Summary saved: {RESULTS_DIR}/summary.txt")


if __name__ == "__main__":
    main()
