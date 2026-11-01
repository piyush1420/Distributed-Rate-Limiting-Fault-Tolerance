"""
Shared utilities for all fault tolerance experiments.
Provides consistent measurement across 04-07.
"""

import subprocess, json, time, os, sys

SSH_KEY = os.path.expanduser("~/.ssh/redisvraft")
PRIVATE_IPS = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]
ALB = "http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com"


def run_aws(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=15).stdout.strip()


def get_public_ip(private_ip):
    return run_aws(["aws", "ec2", "describe-instances",
        "--filters", f"Name=private-ip-address,Values={private_ip}",
        "--query", "Reservations[0].Instances[0].PublicIpAddress", "--output", "text"])


def get_instance_id(private_ip):
    return run_aws(["aws", "ec2", "describe-instances",
        "--filters", f"Name=private-ip-address,Values={private_ip}",
        "--query", "Reservations[0].Instances[0].InstanceId", "--output", "text"])


def ssh_cmd(public_ip, cmd):
    for attempt in range(3):
        try:
            result = subprocess.run(
                ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                 f"ec2-user@{public_ip}", cmd],
                capture_output=True, text=True, timeout=30)
            if result.stdout.strip():
                return result.stdout.strip()
        except Exception:
            pass
        if attempt < 2:
            time.sleep(3)
    return ""


def get_cluster_roles():
    """Get cluster state. Call BEFORE load starts."""
    nodes = []
    for ip in PRIVATE_IPS:
        pub = get_public_ip(ip)
        raw = ssh_cmd(pub, "curl -s http://localhost:8000/status")
        if raw:
            data = json.loads(raw)
            data["private_ip"] = ip
            data["public_ip"] = pub
            nodes.append(data)
        else:
            print(f"  ERROR: Could not reach {ip}")
            sys.exit(1)
    return nodes


def poll_new_leader(old_leader_ip, timeout=30):
    """Poll ALB until a new leader appears. Returns (elapsed, new_leader_addr)."""
    import urllib.request
    start = time.time()
    attempt = 0
    while time.time() - start < timeout:
        attempt += 1
        try:
            req = urllib.request.Request(f"{ALB}/raft/status")
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read())
                leader_addr = data.get("leader_addr", "")
                leader_ip = leader_addr.split(":")[0] if leader_addr else ""
                if leader_ip and leader_ip != old_leader_ip:
                    elapsed = time.time() - start
                    print(f"  [{attempt}] New leader: {leader_addr} (election: {elapsed:.2f}s)")
                    return elapsed, leader_addr
        except Exception:
            pass
        time.sleep(0.5)
    print(f"  TIMEOUT: No new leader after {timeout}s")
    return timeout, "unknown"


def save_summary(results_dir, summary_dict):
    """Save summary.txt to results folder."""
    path = f"{results_dir}/summary.txt"
    with open(path, "w") as f:
        for k, v in summary_dict.items():
            f.write(f"{k}: {v}\n")
    print(f"  Summary saved: {path}")
