#!/bin/bash
#
# 11_experiment_leader_kill_instance.sh
#
# Experiment 2A: Leader node EC2 instance termination (nuclear case).
#
# Simulates complete machine loss — the leader's EC2 instance is fully
# stopped, simulating hardware failure or AZ outage. This is the most
# severe (but rarest) failure mode in production.
#
# Procedure:
#   1. Identify current leader via raft-api /status
#   2. Start background request loop (10 req/sec)
#   3. Stop the leader EC2 instance
#   4. Poll /raft/status every 200ms until a new leader is elected
#   5. Record election duration
#   6. Wait for instance to fully stop, then start it back up
#   7. Wait for Raft container to restart and rejoin cluster
#   8. Verify all 3 nodes are in sync via /raft/debug/per-node
#
# Success criteria:
#   - New leader elected within 5 seconds
#   - Most requests succeed (some 503/504 during election is expected)
#   - Old leader rejoins as Follower (no split-brain)
#   - All 3 nodes in sync after recovery
#
# Usage:
#   ./experiments/11_experiment_leader_kill_instance.sh

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
REQUEST_LOG=/tmp/leader_kill_instance_requests.txt

# ── Step 1: Identify leader ────────────────────────────────────────────────
echo "Step 1: Finding current Raft leader..."
LEADER_ADDR=$(curl -s "$ALB/raft/status" | python3 -c "import sys, json; print(json.load(sys.stdin).get('known_leader',''))")

if [ -z "$LEADER_ADDR" ]; then
  echo "ERROR: No leader found. Aborting."
  exit 1
fi
OLD_LEADER_IP=$(echo "$LEADER_ADDR" | cut -d: -f1)
echo "  Current leader IP: $OLD_LEADER_IP"

VICTIM_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$OLD_LEADER_IP" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
echo "  Leader instance ID: $VICTIM_ID"
echo ""

# ── Step 2: Start background request loop ──────────────────────────────────
echo "Step 2: Starting background request loop..."
rm -f "$REQUEST_LOG"
(
  for i in $(seq 1 600); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB/raft/check?user=LeaderKillInstanceTest" --max-time 2)
    TS=$(date +%s.%N)
    echo "$TS $STATUS" >> "$REQUEST_LOG"
    sleep 0.1
  done
) &
REQUEST_PID=$!
sleep 3
echo "  Warm-up complete"
echo ""

# ── Step 3: Stop leader ────────────────────────────────────────────────────
echo "Step 3: Stopping leader EC2 instance..."
KILL_TS=$(date +%s.%N)
aws ec2 stop-instances --instance-ids "$VICTIM_ID" --output text > /dev/null
echo "  Stop issued at ts=$KILL_TS"
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
  echo "  [$i] Still waiting... (current=$CURRENT)"
  sleep 0.2
done

if [ -z "$NEW_LEADER" ]; then
  echo "  ERROR: No new leader elected within 30s"
else
  ELECTION_DURATION=$(python3 -c "print(round($ELECTION_TS - $KILL_TS, 2))")
  echo "  Election duration: ${ELECTION_DURATION}s"
fi
echo ""

# ── Step 5: Wait for stop to complete, then start back up ──────────────────
echo "Step 5: Waiting for old leader to fully stop..."
aws ec2 wait instance-stopped --instance-ids "$VICTIM_ID"
echo "  Old leader fully stopped. Starting it back up..."
aws ec2 start-instances --instance-ids "$VICTIM_ID" --output text > /dev/null

echo "  Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$VICTIM_ID"
echo "  Instance is running. Waiting 90s for Docker + Raft container to start..."
sleep 90

# ── Step 6: Stop requests and analyze ──────────────────────────────────────
echo ""
echo "Step 6: Analyzing..."
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
echo "HTTP 503/504/failed:   $FAILED  <- expected some during election"
echo ""

# ── Step 7: Verify cluster state ───────────────────────────────────────────
echo "Step 7: Verifying cluster state..."
curl -s "$ALB/raft/status" | python3 -m json.tool

echo ""
echo "============================================"
echo "CLUSTER SYNC VERIFICATION"
echo "============================================"
echo "Waiting 10s for rejoined old leader to catch up..."
sleep 10

DEBUG_JSON=$(curl -s "$ALB/raft/debug/per-node")
echo "$DEBUG_JSON" | python3 -m json.tool

IN_SYNC=$(echo "$DEBUG_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('in_sync'))")
OLD_LEADER_ROLE=$(echo "$DEBUG_JSON" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['nodes']
for n in nodes:
    if n['address'].startswith('$OLD_LEADER_IP'):
        print(n['raft_status'].get('node_state', 'unknown'))
        break
")

echo ""
if [ "$IN_SYNC" = "True" ]; then
  echo "PASS: All 3 Raft nodes are in sync after the failover."
else
  echo "FAIL: Nodes are NOT in sync."
fi

echo "Old leader ($OLD_LEADER_IP) role after rejoin: $OLD_LEADER_ROLE"
if [ "$OLD_LEADER_ROLE" = "Follower" ]; then
  echo "PASS: Old leader correctly rejoined as Follower (no split-brain)."
elif [ "$OLD_LEADER_ROLE" = "Leader" ]; then
  echo "NOTE: Old leader re-elected as Leader."
fi