"""
Standalone cluster check script. Called as separate process to avoid gevent interference.
Usage: python3 cluster_check.py
"""
import subprocess, json, os, time

SSH_KEY = os.path.expanduser("~/.ssh/redisvraft")
PRIVATE_IPS = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]

results = []
for ip in PRIVATE_IPS:
    pub = subprocess.run(
        ["aws", "ec2", "describe-instances", "--filters", f"Name=private-ip-address,Values={ip}",
         "--query", "Reservations[0].Instances[0].PublicIpAddress", "--output", "text"],
        capture_output=True, text=True, timeout=15
    ).stdout.strip()

    for attempt in range(3):
        try:
            raw = subprocess.run(
                ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                 f"ec2-user@{pub}", "curl -s http://localhost:8000/status"],
                capture_output=True, text=True, timeout=30
            ).stdout.strip()
            if raw:
                d = json.loads(raw)
                print(f"  {ip}: state={d['node_state']}  leader={d['leader_id']}  applied={d['applied_index']}")
                results.append(d['applied_index'])
                break
        except Exception as e:
            pass
        if attempt < 2:
            time.sleep(5)
    else:
        print(f"  {ip}: UNREACHABLE after 3 attempts")

if len(results) == 3:
    spread = max(results) - min(results)
    if spread <= 5:
        print(f"  PASS: All 3 nodes in sync (spread={spread})")
    else:
        print(f"  NOTE: Index spread = {spread} (catching up)")
else:
    print(f"  WARNING: Only {len(results)}/3 nodes responded")
