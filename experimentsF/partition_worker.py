"""
Standalone partition worker. Runs OUTSIDE gevent.
Usage: python3 partition_worker.py <leader_private_ip> <output_file>
"""
import subprocess, json, time, sys, os

SSH_KEY = os.path.expanduser("~/.ssh/redisvraft")
PRIVATE_IPS = ["10.0.0.10", "10.0.0.11", "10.0.0.12"]

leader_ip = sys.argv[1]
output_file = sys.argv[2]
follower_ips = [ip for ip in PRIVATE_IPS if ip != leader_ip]


def get_pub(private_ip):
    return subprocess.run(
        ["aws", "ec2", "describe-instances", "--filters", f"Name=private-ip-address,Values={private_ip}",
         "--query", "Reservations[0].Instances[0].PublicIpAddress", "--output", "text"],
        capture_output=True, text=True, timeout=15).stdout.strip()


def ssh(pub, cmd):
    return subprocess.run(
        ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
         f"ec2-user@{pub}", cmd],
        capture_output=True, text=True, timeout=30).stdout.strip()


leader_pub = get_pub(leader_ip)
follower_pubs = [(ip, get_pub(ip)) for ip in follower_ips]

# Apply partition
print(f"Applying iptables on {leader_ip} ({leader_pub})...")
ssh(leader_pub, "sudo iptables -A INPUT -p tcp --dport 7000 -j DROP")
ssh(leader_pub, "sudo iptables -A INPUT -p tcp --dport 8000 -j DROP")
ssh(leader_pub, "sudo iptables -A OUTPUT -p tcp --dport 7000 -j DROP")
ssh(leader_pub, "sudo iptables -A OUTPUT -p tcp --dport 8000 -j DROP")
partition_time = time.time()
print(f"Partition applied at {time.strftime('%H:%M:%S')}")

# Poll followers for new leader
print("Polling followers for election...")
election_time = 30.0
new_leader = "unknown"
for attempt in range(60):
    for fip, fpub in follower_pubs:
        try:
            raw = ssh(fpub, "curl -s http://localhost:8000/status")
            if raw:
                data = json.loads(raw)
                if data["node_state"] == "Leader":
                    election_time = time.time() - partition_time
                    new_leader = f"{fip}:7000"
                    print(f"[{attempt+1}] {fip} became leader (election: {election_time:.2f}s)")
                    break
                la = data.get("leader_addr", "")
                la_ip = la.split(":")[0] if la else ""
                if la_ip and la_ip != leader_ip:
                    election_time = time.time() - partition_time
                    new_leader = la
                    print(f"[{attempt+1}] New leader: {la} via {fip} (election: {election_time:.2f}s)")
                    break
        except Exception:
            pass
    else:
        time.sleep(0.5)
        continue
    break
else:
    print(f"TIMEOUT: No new leader after 30s")

# Write results
result = {"election_time": election_time, "new_leader": new_leader, "partition_time": partition_time}
with open(output_file, "w") as f:
    json.dump(result, f)
print(f"Results written to {output_file}")
