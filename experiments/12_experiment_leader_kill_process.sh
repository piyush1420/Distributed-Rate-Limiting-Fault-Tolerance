#!/bin/bash
#
# 12_experiment_leader_kill_process.sh
#
# Experiment 2B: Process-level kill of the leader's Raft container.
#
# Uses SSH + docker stop to kill ONLY the Raft process. The EC2 instance stays
# alive, OS keeps running, BoltDB stays warm, Docker daemon is still there.
# This simulates the most common real-world failure: process crash / OOM /
# panic / deploy mishap. Recovery is faster than instance termination because
# we skip the full boot cycle.
#
# Expected:
#   - Election time similar to Exp 2A (~2-3s), as OS-level process exit
#     closes TCP connections cleanly (unlike iptables in Exp 3)
#   - Faster recovery: just docker start vs 90s EC2 reboot
#
# Usage:
#   ./experiments/12_experiment_leader_kill_process.sh

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
REQUEST_LOG=/tmp/leader_kill_process_requests.txt
SSH_KEY=~/.ssh/redisvraft

# Cleanup function: make sure the Raft container is running, even if script fails
cleanup_container() {
  if [ -n "${LEADER_PUBLIC_IP:-}" ]; then
    echo ""
    echo "SAFETY CLEANUP: ensuring raft-node container is running..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP \
      "sudo docker start raft-node 2>/dev/null || true" 2>/dev/null || true
    echo "  Cleanup done"
  fi
}
trap cleanup_container EXIT

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
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB/raft/check?user=LeaderKillProcessTest" --max-time 2)
    TS=$(date +%s.%N)
    echo "$TS $STATUS" >> "$REQUEST_LOG"
    sleep 0.1
  done
) &
REQUEST_PID=$!
sleep 3
echo "  Warm-up complete"
echo ""

# ── Step 3: Kill the Raft container on the leader ──────────────────────────
echo "Step 3: Stopping raft-node container via docker stop..."
KILL_TS=$(date +%s.%N)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP \
  "sudo docker stop raft-node"
echo "  Container stopped at ts=$KILL_TS"
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
  ELECTION_DURATION=$(python3 -c "print(round($ELECTION_TS - $KILL_TS, 2))")
  echo "  Election duration: ${ELECTION_DURATION}s"
fi
echo ""

# ── Step 5: Restart the killed container ───────────────────────────────────
echo "Step 5: Starting raft-node container back up..."
RESTART_TS=$(date +%s.%N)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LEADER_PUBLIC_IP \
  "sudo docker start raft-node"
echo "  Container start issued at ts=$RESTART_TS"
echo "  Waiting 15s for container to rejoin cluster..."
sleep 15

# ── Step 6: Stop requests and analyze ──────────────────────────────────────
echo ""
echo "Step 6: Analyzing requests..."
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

# ── Step 7: Verify sync ────────────────────────────────────────────────────
echo "Step 7: Verifying cluster sync..."
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
  echo "PASS: All 3 Raft nodes are in sync after container restart."
else
  echo "FAIL: Nodes are NOT in sync."
fi

echo "Old leader ($LEADER_IP_PRIVATE) role after rejoin: $OLD_LEADER_ROLE"
if [ "$OLD_LEADER_ROLE" = "Follower" ]; then
  echo "PASS: Old leader correctly rejoined as Follower."
elif [ "$OLD_LEADER_ROLE" = "Leader" ]; then
  echo "NOTE: Old leader re-elected as Leader."
fi