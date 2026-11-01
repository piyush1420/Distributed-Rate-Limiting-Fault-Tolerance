#!/bin/bash
#
# 10_experiment_follower_kill.sh
#
# Experiment 1: Verify the Raft cluster survives losing a follower node.
#
# Procedure:
#   1. Identify current leader via raft-api /status
#   2. Pick a non-leader EC2 instance as the victim
#   3. Start a background loop sending rate-limit requests (1 per 100ms)
#   4. Stop the victim EC2 instance (simulates node failure)
#   5. Wait 30 seconds while requests continue
#   6. Start the victim instance back up
#   7. Wait for it to rejoin and catch up
#   8. Report: request success rate, catch-up time
#
# Success criteria:
#   - 100% request success rate during the kill window
#   - Failed node rejoins cluster within ~60 seconds
#   - Raft log is consistent across all 3 nodes after recovery
#
# Usage:
#   ./scripts/10_experiment_follower_kill.sh

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
REQUEST_LOG=/tmp/follower_kill_requests.txt
KILL_DURATION=30

# ── Step 1: Identify leader and pick victim ────────────────────────────────
echo "Step 1: Finding current Raft leader..."
LEADER_ADDR=$(curl -s "$ALB/raft/status" | python3 -c "import sys, json; print(json.load(sys.stdin).get('known_leader',''))")

if [ -z "$LEADER_ADDR" ]; then
  echo "ERROR: No leader found. Aborting."
  exit 1
fi
LEADER_IP=$(echo "$LEADER_ADDR" | cut -d: -f1)
echo "  Leader IP: $LEADER_IP"

# Pick a non-leader node
for NODE_IP in 10.0.0.10 10.0.0.11 10.0.0.12; do
  if [ "$NODE_IP" != "$LEADER_IP" ]; then
    VICTIM_IP=$NODE_IP
    break
  fi
done
echo "  Victim IP: $VICTIM_IP (follower)"

VICTIM_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$VICTIM_IP" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
echo "  Victim instance ID: $VICTIM_ID"
echo ""

# ── Step 2: Start background request loop ──────────────────────────────────
echo "Step 2: Starting background request loop..."
rm -f "$REQUEST_LOG"
(
  for i in $(seq 1 600); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB/raft/check?user=FollowerKillTest" --max-time 2)
    TS=$(date +%s.%N)
    echo "$TS $STATUS" >> "$REQUEST_LOG"
    sleep 0.1
  done
) &
REQUEST_PID=$!
echo "  Background loop PID: $REQUEST_PID"
sleep 5
echo "  Warm-up complete"
echo ""

# ── Step 3: Stop victim instance ───────────────────────────────────────────
echo "Step 3: Stopping victim EC2 instance..."
KILL_START=$(date +%s)
aws ec2 stop-instances --instance-ids "$VICTIM_ID" --output text > /dev/null
echo "  Stop command issued at $(date)"

# ── Step 4: Wait 30 seconds ─────────────────────────────────────────────────
echo "Step 4: Waiting $KILL_DURATION seconds with node down..."
sleep $KILL_DURATION
KILL_END=$(date +%s)
echo ""

# ── Step 5: Start victim back up ───────────────────────────────────────────
echo "Step 5: Starting victim instance back up..."
aws ec2 start-instances --instance-ids "$VICTIM_ID" --output text > /dev/null
echo "  Start command issued at $(date)"
echo "  Waiting for instance to rejoin (max 120s)..."

# Wait for the victim to come back and rejoin
for i in $(seq 1 24); do
  STATE=$(aws ec2 describe-instances --instance-ids "$VICTIM_ID" \
    --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
  if [ "$STATE" = "running" ]; then
    echo "  [$i] Instance is running again"
    break
  fi
  echo "  [$i] State: $STATE — waiting 5s"
  sleep 5
done

# Wait for EC2 user-data to run and container to rejoin cluster
echo "  Waiting 60s for Raft container to start and rejoin..."
sleep 60

# ── Step 6: Stop the request loop and analyze ──────────────────────────────
echo ""
echo "Step 6: Stopping request loop and analyzing..."
kill $REQUEST_PID 2>/dev/null || true
wait $REQUEST_PID 2>/dev/null || true

TOTAL=$(wc -l < "$REQUEST_LOG" | tr -d ' ')
SUCCESS=$(grep -c ' 200$' "$REQUEST_LOG" || echo 0)
REJECTED=$(grep -c ' 429$' "$REQUEST_LOG" || echo 0)
FAILED=$(grep -cE ' (503|504|000)$' "$REQUEST_LOG" 2>/dev/null || echo 0)
echo ""
echo "============================================"
echo "RESULTS"
echo "============================================"
echo "Total requests:        $TOTAL"
echo "HTTP 200 (allowed):    $SUCCESS"
echo "HTTP 429 (rate-lim):   $REJECTED  <- expected, bucket drained"
echo "HTTP 503/504/failed:   $FAILED     <- these indicate outage"
echo ""

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: Zero failures during follower kill. Raft tolerated the loss."
else
  echo "NOTE: $FAILED requests failed during the kill window."
fi
echo ""
echo "Verifying cluster has leader again..."
curl -s "$ALB/raft/status" | python3 -m json.tool

echo "Verifying cluster has leader again..."
curl -s "$ALB/raft/status" | python3 -m json.tool

echo ""
echo "============================================"
echo "CLUSTER SYNC VERIFICATION"
echo "============================================"
echo "Waiting 10s for rejoined node to catch up..."
sleep 10

echo ""
echo "Calling /raft/debug/per-node..."
DEBUG_JSON=$(curl -s "$ALB/raft/debug/per-node")
echo "$DEBUG_JSON" | python3 -m json.tool

IN_SYNC=$(echo "$DEBUG_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('in_sync'))")

echo ""
if [ "$IN_SYNC" = "True" ]; then
  echo "PASS: All 3 Raft nodes are in sync after the rejoin."
else
  echo "FAIL: Nodes are NOT in sync after the rejoin. Check output above."
fi