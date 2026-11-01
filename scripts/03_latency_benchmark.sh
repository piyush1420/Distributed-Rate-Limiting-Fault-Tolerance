#!/bin/bash
#
# 03_latency_benchmark.sh
#
# Measures end-to-end request latency for both systems.
# Output is laptop→AWS→laptop total time, so subtract ~50-80ms
# network round-trip baseline to get actual in-AWS decision time.
#
# Usage:
#   ./scripts/03_latency_benchmark.sh
#
# Expected on AWS:
#   Redis:             50-100ms per request
#   Raft cache miss:   80-150ms per request (network + Raft consensus)
#   Raft cache hit:    50-100ms per request (network + local cache lookup)

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com

echo "============================="
echo "Redis — 20 sequential timings"
echo "============================="
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{time_total}s  " "$ALB/check?user=RedisLatencyTest"
done
echo ""
echo ""

echo "============================="
echo "Raft — cache miss (fresh user each time)"
echo "============================="
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{time_total}s  " "$ALB/raft/check?user=RaftMiss-$i-$(date +%s%N)"
done
echo ""
echo ""

echo "============================="
echo "Raft — cache hit (same user repeatedly)"
echo "============================="
curl -s -o /dev/null "$ALB/raft/check?user=RaftWarm"
sleep 0.1
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{time_total}s  " "$ALB/raft/check?user=RaftWarm"
done
echo ""