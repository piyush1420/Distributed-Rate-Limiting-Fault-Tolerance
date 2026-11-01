#!/bin/bash
#
# 13_experiment_network_partition.sh
#
# Experiment 3: True network partition isolating the leader.
#
# Uses iptables via SSH to drop all Raft-related traffic (ports 7000, 8000)
# on the leader instance. Unlike AWS Security Groups, iptables is stateless
# at the OS level and immediately breaks long-lived TCP connections — the
# only way to simulate a real network partition on AWS between same-subnet
# instances.
#
# The leader becomes the minority side (1 node alone). The two remaining
# followers form the majority quorum (2 of 3). Expected behavior:
#   - New leader elected on the majority side in ~2-3s
#   - Old (isolated) leader cannot commit writes (no majority)
#   - After partition heal, old leader rejoins as Follower and catches up
#   - No split-brain: only one valid leader at any moment
#
# Usage:
#   ./experiments/13_experiment_network_partition.sh

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
REQUEST_LOG=/tmp/network_partition_requests.txt
SSH_KEY=~/.ssh/redisvraft

# Cleanup function — always removes iptables rules on exit, even if script fails
cleanup_iptables() {
  if [ -n "${LEADER_PUBLIC_IP:-}" ]; then
    echo ""
    echo "SAFETY CLEANUP: restoring leader network connectivity..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP \
      "sudo iptables -F INPUT && sudo iptables -F OUTPUT" 2>/dev/null || true
    echo "  Cleanup done"
  fi
}
trap cleanup_iptables EXIT

# ── Step 1: Identify leader ────────────────────────────────────────────────
echo "Step 1: Finding current Raft leader..."
LEADER_ADDR=$(curl -s "$ALB/raft/status" | python3 -c "import sys, json; print(json.load(sys.stdin).get('known_leader',''))")

if [ -z "$LEADER_ADDR" ]; then
  echo "ERROR: No leader found. Aborting."
  exit 1
fi
LEADER_IP_PRIVATE=$(echo "$LEADER_ADDR" | cut -d: -f1)
echo "  Current leader private IP: $LEADER_IP_PRIVATE"

LEADER_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$LEADER_IP_PRIVATE" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
LEADER_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$LEADER_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "  Current leader public IP:  $LEADER_PUBLIC_IP"
echo ""

# ── Step 2: Start background request loop ──────────────────────────────────
echo "Step 2: Starting background request loop..."
rm -f "$REQUEST_LOG"
(
  for i in $(seq 1 600); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB/raft/check?user=NetworkPartitionTest" --max-time 2)
    TS=$(date +%s.%N)
    echo "$TS $STATUS" >> "$REQUEST_LOG"
    sleep 0.1
  done
) &
REQUEST_PID=$!
sleep 3
echo "  Warm-up complete"
echo ""

# ── Step 3: Apply iptables partition on the leader ─────────────────────────
echo "Step 3: Partitioning leader via iptables (TCP connections will break)..."
PARTITION_TS=$(date +%s.%N)

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP "
  sudo iptables -A INPUT  -p tcp --dport 7000 -j DROP &&
  sudo iptables -A INPUT  -p tcp --dport 8000 -j DROP &&
  sudo iptables -A OUTPUT -p tcp --dport 7000 -j DROP &&
  sudo iptables -A OUTPUT -p tcp --dport 8000 -j DROP
"

echo "  Partition active at ts=$PARTITION_TS"
echo "  (Leader is now cut off from Raft peer traffic and raft-api forwards)"
echo ""

# ── Step 4: Poll for new leader ────────────────────────────────────────────
echo "Step 4: Polling for new leader election (max 30s)..."
NEW_LEADER=""
ELECTION_TS=""
for i in $(seq 1 150); do
  CURRENT=$(curl -s "$ALB/raft/status" --max-time 2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('known_leader',''))" 2>/dev/null || echo "")
  if [ -n "$CURRENT" ] && [ "$CURRENT" != "$LEADER_ADDR" ]; then
    NEW_LEADER=$CURRENT
    ELECTION_TS=$(date +%s.%N)
    echo "  [$i] New leader detected: $NEW_LEADER"
    break
  fi
  sleep 0.2
done

if [ -z "$NEW_LEADER" ]; then
  echo "  WARNING: No new leader elected within 30s"
else
  ELECTION_DURATION=$(python3 -c "print(round($ELECTION_TS - $PARTITION_TS, 2))")
  echo "  Election duration: ${ELECTION_DURATION}s"
fi
echo ""

# ── Step 5: Hold partition to test split-brain prevention ─────────────────
echo "Step 5: Holding partition for 20s (testing split-brain prevention)..."
sleep 20
echo ""

# ── Step 6: Heal partition ────────────────────────────────────────────────
echo "Step 6: Healing partition (removing iptables rules)..."
HEAL_TS=$(date +%s.%N)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP \
  "sudo iptables -F INPUT && sudo iptables -F OUTPUT"
echo "  Partition healed at ts=$HEAL_TS"
echo "  Waiting 15s for old leader to rejoin..."
sleep 15

# ── Step 7: Analyze request log ────────────────────────────────────────────
echo ""
echo "Step 7: Analyzing requests..."
kill $REQUEST_PID 2>/dev/null || true
wait $REQUEST_PID 2>/dev/null || true

TOTAL=$(wc -l < "$REQUEST_LOG" | tr -d ' ')
SUCCESS=$(grep -cE ' 200$' "$REQUEST_LOG" 2>/dev/null || echo 0)
REJECTED=$(grep -cE ' 429$' "$REQUEST_LOG" 2>/dev/null || echo 0)
FAILED=$(grep -cE ' (503|504|000)$' "$REQUEST_LOG" 2>/dev/null || echo 0)

echo ""
echo "============================================"
echo "RESULTS"
echo "============================================"
echo "Old leader:            $LEADER_ADDR"
echo "New leader:            $NEW_LEADER"
if [ -n "$NEW_LEADER" ]; then
  echo "Election time:         ${ELECTION_DURATION}s"
fi
echo ""
echo "Total requests:        $TOTAL"
echo "HTTP 200 (allowed):    $SUCCESS"
echo "HTTP 429 (rate-lim):   $REJECTED"
echo "HTTP 503/504/failed:   $FAILED"
echo ""

# ── Step 8: Cluster sync verification ──────────────────────────────────────
echo "Step 8: Verifying cluster sync..."
DEBUG_JSON=$(curl -s "$ALB/raft/debug/per-node")
echo "$DEBUG_JSON" | python3 -m json.tool

IN_SYNC=$(echo "$DEBUG_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('in_sync'))")
OLD_LEADER_ROLE=$(echo "$DEBUG_JSON" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['nodes']
for n in nodes:
    if n['address'].startswith('$LEADER_IP_PRIVATE'):
        print(n['raft_status'].get('node_state', 'unknown'))
        break
")

echo ""
if [ "$IN_SYNC" = "True" ]; then
  echo "PASS: All 3 Raft nodes are in sync after partition heal."
else
  echo "FAIL: Nodes are NOT in sync."
fi

echo "Old leader ($LEADER_IP_PRIVATE) role after heal: $OLD_LEADER_ROLE"
if [ "$OLD_LEADER_ROLE" = "Follower" ]; then
  echo "PASS: Old leader correctly rejoined as Follower (no split-brain)."
elif [ "$OLD_LEADER_ROLE" = "Leader" ]; then
  echo "NOTE: Old leader re-elected as Leader."
fi