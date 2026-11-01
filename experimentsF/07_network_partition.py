"""
07_network_partition.py
Partitions the Raft leader via iptables while Locust load is running.
Partition + election detection runs as SEPARATE process (avoids gevent).
Observation window: exactly 60s from partition event.
"""

import glob, json, os, random, time, sys, subprocess, gevent
from locust import HttpUser, task, between
from locust.env import Environment
from locust.stats import stats_printer, stats_history, StatsCSVFileWriter
from locust.html import get_html_report
from locust.log import setup_logging

setup_logging("INFO")

ALB = "http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com"
RESULTS_DIR = os.path.expanduser("~/Desktop/Go/raft-rate-limiter/RedisVsRaft-Consistency/resultsF/07_network_partition")
SSH_KEY = os.path.expanduser("~/.ssh/redisvraft")
PRIVATE_IPS = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
OBSERVATION_WINDOW = 60
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def get_public_ip(private_ip):
    return subprocess.run(
        ["aws", "ec2", "describe-instances", "--filters", f"Name=private-ip-address,Values={private_ip}",
         "--query", "Reservations[0].Instances[0].PublicIpAddress", "--output", "text"],
        capture_output=True, text=True, timeout=15).stdout.strip()


def ssh(public_ip, cmd):
    result = subprocess.run(
        ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
         f"ec2-user@{public_ip}", cmd],
        capture_output=True, text=True, timeout=30)
    return result.stdout.strip()


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
    csv_prefix = f"{RESULTS_DIR}/network_partition_{ts}"
    html_path = f"{RESULTS_DIR}/network_partition_{ts}.html"
    worker_output = f"{RESULTS_DIR}/partition_result_{ts}.json"

    print("=" * 60)
    print("EXPERIMENT 07: NETWORK PARTITION UNDER LOAD")
    print(f"Observation window: {OBSERVATION_WINDOW}s from partition")
    print("=" * 60)

    # Step 1: Identify roles via SSH (before load)
    print("\nStep 1: Identifying cluster roles...")
    leader_ip = None
    follower_ips = []
    pub_ips = {}
    for ip in PRIVATE_IPS:
        pub = get_public_ip(ip)
        pub_ips[ip] = pub
        raw = ssh(pub, "curl -s http://localhost:8000/status")
        if not raw:
            print(f"  ERROR: Cannot reach {ip}")
            sys.exit(1)
        data = json.loads(raw)
        role = data["node_state"]
        print(f"  {ip}: {role}  leader={data['leader_id']}  applied={data['applied_index']}")
        if role == "Leader":
            leader_ip = ip
        else:
            follower_ips.append(ip)

    if not leader_ip or len(follower_ips) < 2:
        print("ERROR: Need 1 leader and 2 followers. Aborting.")
        sys.exit(1)

    print(f"\n  Leader: {leader_ip}")

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
    print(f"  Pre-partition: {pre_reqs} requests, {pre_fails} failures")

    # Step 3: Launch partition worker as SEPARATE PROCESS
    print(f"\nStep 3: Launching partition worker (separate process)...")
    kill_time = time.time()
    worker = subprocess.Popen(
        ["python3", os.path.join(SCRIPT_DIR, "partition_worker.py"), leader_ip, worker_output],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    # Step 4: Wait for worker to finish (max 45s)
    print("\nStep 4: Waiting for partition + election detection...")
    try:
        stdout, stderr = worker.communicate(timeout=45)
        print(stdout)
        if stderr:
            print(f"  stderr: {stderr[:200]}")
    except subprocess.TimeoutExpired:
        worker.kill()
        print("  Worker timed out")

    # Read election results
    election_time = 30.0
    new_leader = "unknown"
    try:
        with open(worker_output) as f:
            result = json.load(f)
        election_time = result["election_time"]
        new_leader = result["new_leader"]
    except Exception as e:
        print(f"  Could not read worker output: {e}")

    # Remaining observation window
    elapsed = time.time() - kill_time
    remaining = max(0, OBSERVATION_WINDOW - elapsed)
    print(f"\n  Continuing observation for {remaining:.1f}s more...")
    gevent.sleep(remaining)

    obs_reqs = env.stats.total.num_requests - pre_reqs
    obs_fails = env.stats.total.num_failures - pre_fails
    obs_success = ((obs_reqs - obs_fails) / obs_reqs * 100) if obs_reqs > 0 else 0
    print(f"  Observation window results:")
    print(f"    Requests:  {obs_reqs}")
    print(f"    Failures:  {obs_fails}")
    print(f"    Success:   {obs_success:.2f}%")

    # Step 5: Heal partition
    print(f"\nStep 5: Healing partition...")
    leader_pub = pub_ips[leader_ip]
    subprocess.run(["python3", "-c", f"""
import subprocess
subprocess.run(["ssh","-i","{SSH_KEY}","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10",
    "ec2-user@{leader_pub}","sudo iptables -F"], capture_output=True, text=True, timeout=30)
print("Partition healed")
"""], capture_output=True, text=True, timeout=30)
    print(f"  Partition healed at {time.strftime('%H:%M:%S')}")
    print("  Waiting 15s for old leader to rejoin...")
    gevent.sleep(15)

    # Step 6: Check old leader rejoin (external process)
    print("\nStep 6: Checking old leader rejoin...")
    rejoin_result = subprocess.run(["python3", "-c", f"""
import subprocess, json, os
raw = subprocess.run(["ssh","-i","{SSH_KEY}","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10",
    "ec2-user@{leader_pub}","curl -s http://localhost:8000/status"],
    capture_output=True, text=True, timeout=30).stdout.strip()
if raw:
    d = json.loads(raw)
    print(f"  State: {{d['node_state']}}  leader: {{d['leader_id']}}  applied: {{d['applied_index']}}")
    if d['node_state'] == 'Follower':
        print("  PASS: Old leader rejoined as Follower (no split-brain)")
else:
    print("  WARNING: Not reachable")
"""], capture_output=True, text=True, timeout=30)
    print(rejoin_result.stdout)

    recovery_time = time.time() - kill_time

    # Stop Locust
    print("\nStopping Locust...")
    env.runner.quit()
    time.sleep(25)

    total_reqs = env.stats.total.num_requests
    total_fails = env.stats.total.num_failures

    # Step 7: Final cluster check (external process)
    print("\nStep 7: Final cluster state...")
    subprocess.run(["python3", os.path.join(SCRIPT_DIR, "cluster_check.py")], timeout=120)

    # Safety: flush iptables on all nodes
    print("\nSafety cleanup...")
    for ip in PRIVATE_IPS:
        try:
            subprocess.run(["python3", "-c", f"""
import subprocess
subprocess.run(["ssh","-i","{SSH_KEY}","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10",
    "ec2-user@{pub_ips[ip]}","sudo iptables -F"], capture_output=True, text=True, timeout=30)
print("  {ip}: flushed")
"""], capture_output=True, text=True, timeout=30)
        except:
            pass

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
        "experiment": "07_network_partition",
        "old_leader": leader_ip,
        "new_leader": new_leader,
        "election_time_s": f"{election_time:.2f}",
        "partition_method": "iptables DROP on ports 7000 and 8000",
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

    with open(f"{RESULTS_DIR}/summary.txt", "w") as sf:
        for k, v in summary.items():
            sf.write(f"{k}: {v}\n")
    print(f"  Summary saved: {RESULTS_DIR}/summary.txt")


if __name__ == "__main__":
    main()
