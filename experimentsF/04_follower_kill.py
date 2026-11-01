"""
04_follower_kill.py
Kills a Raft follower while Locust load is running.
Observation window: exactly 60s from kill event.
"""

import glob, json, os, random, time, sys, gevent
from locust import HttpUser, task, between
from locust.env import Environment
from locust.stats import stats_printer, stats_history, StatsCSVFileWriter
from locust.html import get_html_report
from locust.log import setup_logging

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from raft_experiment_base import *

setup_logging("INFO")

RESULTS_DIR = os.path.expanduser("~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency/resultsF/04_follower_kill")
OBSERVATION_WINDOW = 60  # seconds — same for all experiments


class RaftUser(HttpUser):
    host = ALB
    wait_time = between(0.01, 0.05)
    def on_start(self):
        self.user_id = f"user-{random.randint(1, 1000)}"
    @task(8)
    def check_rate_limit(self):
        with self.client.get(f"/raft/check?user={self.user_id}", name="/raft/check", catch_response=True) as resp:
            if resp.status_code in (200, 429):
                resp.success()
            else:
                resp.failure(f"status {resp.status_code}")
    @task(1)
    def health(self):
        self.client.get("/raft/health", name="/raft/health")
    @task(1)
    def status(self):
        self.client.get("/raft/status", name="/raft/status")


def main():
    for f in glob.glob(f"{RESULTS_DIR}/*"):
        os.remove(f)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    ts = int(time.time())
    csv_prefix = f"{RESULTS_DIR}/follower_kill_{ts}"
    html_path = f"{RESULTS_DIR}/follower_kill_{ts}.html"

    print("=" * 60)
    print("EXPERIMENT 04: FOLLOWER KILL UNDER LOAD (RAW RAFT)")
    print(f"Observation window: {OBSERVATION_WINDOW}s from kill event")
    print("=" * 60)

    # Step 1: Identify roles
    print("\nStep 1: Identifying cluster roles...")
    nodes = get_cluster_roles()
    leader = None
    follower = None
    for n in nodes:
        role = n.get("node_state", "?")
        print(f"  {n['private_ip']}: {role}  leader_id={n.get('leader_id','?')}  applied={n.get('applied_index','?')}")
        if role == "Leader":
            leader = n
        elif role == "Follower" and follower is None:
            follower = n

    if not leader or not follower:
        print("ERROR: Need leader and follower. Aborting.")
        sys.exit(1)

    follower_instance_id = get_instance_id(follower["private_ip"])
    print(f"\n  Leader:    {leader['private_ip']}")
    print(f"  Target:    {follower['private_ip']} (instance={follower_instance_id})")

    # Step 2: Start Locust
    print("\nStep 2: Starting Locust (200 users)...")
    env = Environment(user_classes=[RaftUser])
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

    # Step 3: Kill follower — snapshot and start observation window
    print(f"\nStep 3: Stopping follower {follower_instance_id}...")
    kill_time = time.time()
    subprocess.run(["aws", "ec2", "stop-instances", "--instance-ids", follower_instance_id],
        capture_output=True, text=True, timeout=15)
    print(f"  Stop command sent at {time.strftime('%H:%M:%S')}")

    # Step 4: Observation window — exactly OBSERVATION_WINDOW seconds from kill
    print(f"\nStep 4: Observing for exactly {OBSERVATION_WINDOW}s...")
    gevent.sleep(OBSERVATION_WINDOW)

    obs_reqs = env.stats.total.num_requests - pre_reqs
    obs_fails = env.stats.total.num_failures - pre_fails
    obs_success = ((obs_reqs - obs_fails) / obs_reqs * 100) if obs_reqs > 0 else 0
    print(f"  Observation window results:")
    print(f"    Requests:  {obs_reqs}")
    print(f"    Failures:  {obs_fails}")
    print(f"    Success:   {obs_success:.2f}%")

    # Step 5: Restart follower
    print(f"\nStep 5: Restarting follower {follower_instance_id}...")
    subprocess.run(["aws", "ec2", "start-instances", "--instance-ids", follower_instance_id],
        capture_output=True, text=True, timeout=15)
    print("  Waiting for instance running...")
    subprocess.run(["aws", "ec2", "wait", "instance-running", "--instance-ids", follower_instance_id],
        capture_output=True, text=True, timeout=300)
    recovery_time = time.time() - kill_time
    print(f"  Instance running after {recovery_time:.1f}s")
    print("  Waiting 30s for Raft to boot...")
    gevent.sleep(30)

    # Step 6: Check follower rejoin (while Locust still runs — but load is lighter now)
    print("\nStep 6: Checking follower rejoin...")
    try:
        pub = get_public_ip(follower["private_ip"])
        raw = ssh_cmd(pub, "curl -s http://localhost:8000/status")
        if raw:
            data = json.loads(raw)
            print(f"  State: {data['node_state']}  leader: {data['leader_id']}  applied: {data['applied_index']}")
            if data["applied_index"] > 0 and data["leader_id"]:
                print("  PASS: Follower rejoined cluster")
            else:
                print("  WARNING: Follower may need manual join")
        else:
            print("  WARNING: Follower not reachable yet")
    except Exception as e:
        print(f"  Could not check: {e}")

    # Stop Locust
    print("\nStopping Locust...")
    env.runner.quit()
    time.sleep(25)

    total_reqs = env.stats.total.num_requests
    total_fails = env.stats.total.num_failures

    # Step 7: Final cluster check (external process)
    print("\nStep 7: Final cluster state...")
    subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cluster_check.py")], timeout=120)

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
        "experiment": "04_follower_kill",
        "target": f"{follower['private_ip']} ({follower_instance_id})",
        "leader": leader["private_ip"],
        "election_triggered": "No",
        "observation_window_s": OBSERVATION_WINDOW,
        "obs_requests": obs_reqs,
        "obs_failures": obs_fails,
        "obs_success_rate": f"{obs_success:.2f}%",
        "total_requests": total_reqs,
        "total_failures": total_fails,
        "recovery_time_s": f"{recovery_time:.1f}",
        "html_report": html_path,
    }

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for k, v in summary.items():
        print(f"  {k}: {v}")
    print("=" * 60)
    save_summary(RESULTS_DIR, summary)

if __name__ == "__main__":
    main()
