#!/bin/bash
#
# 21_ecs_task_monitor.sh
#
# Polls ECS every 10 seconds and records how many raft-api tasks
# are running. Run this in a SEPARATE terminal alongside the Locust
# ramp test (21_locust_ramp_raft_cached.py).
#
# Output goes to results/ecs_task_count_<timestamp>.csv
# Format: timestamp, running_tasks, pending_tasks, locust_users_approx
#
# Usage:
#   ./experiments/21_ecs_task_monitor.sh
#   (Press Ctrl+C to stop when Locust finishes)

CLUSTER="redisvraft-cluster"
SERVICE="redisvraft-raft-api"
OUTPUT="results/ecs_task_count_$(date +%s).csv"
INTERVAL=10

mkdir -p results

echo "timestamp,elapsed_secs,running_tasks,pending_tasks,desired_tasks" > "$OUTPUT"
echo "Monitoring ECS task count every ${INTERVAL}s → $OUTPUT"
echo "Press Ctrl+C to stop."
echo ""
echo "timestamp                | elapsed | running | pending | desired"
echo "─────────────────────────────────────────────────────────────────"

START_TS=$(date +%s)

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  # Get task counts from ECS
  RESULT=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query "services[0].[runningCount,pendingCount,desiredCount]" \
    --output text 2>/dev/null)

  RUNNING=$(echo "$RESULT" | awk '{print $1}')
  PENDING=$(echo "$RESULT" | awk '{print $2}')
  DESIRED=$(echo "$RESULT" | awk '{print $3}')

  # Handle empty/error response
  RUNNING=${RUNNING:-0}
  PENDING=${PENDING:-0}
  DESIRED=${DESIRED:-0}

  # Write to CSV
  echo "$TIMESTAMP,$ELAPSED,$RUNNING,$PENDING,$DESIRED" >> "$OUTPUT"

  # Print to terminal
  printf "%-25s| %-8s| %-8s| %-8s| %-8s\n" \
    "$TIMESTAMP" "${ELAPSED}s" "$RUNNING" "$PENDING" "$DESIRED"

  sleep $INTERVAL
done
