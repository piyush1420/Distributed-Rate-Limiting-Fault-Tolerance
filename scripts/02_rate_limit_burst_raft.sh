#!/bin/bash
#
# 02_rate_limit_burst_raft.sh
#
# Prove Raft side enforces the token bucket limit.
# Same 200-parallel-request pattern as the Redis version, but hits /raft/check.
#
# Because raft-api has a 1-second per-task cache in front of the Raft cluster,
# results may show slightly more 200s than the Redis version (cache drift —
# this is the documented tradeoff). Expect ~100-120 "200" and ~80-100 "429".
#
# Usage:
#   ./scripts/02_rate_limit_burst_raft.sh
#
# Expected output (approximate):
#    100-120 "200"
#    80-100  "429"

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
USER="RaftBurst-$(date +%s)"
TOTAL=200
PARALLEL=50
TMP=/tmp/raft_burst_$$.txt

echo "Firing $TOTAL requests for user=$USER ($PARALLEL parallel)..."

seq 1 $TOTAL | xargs -n1 -P$PARALLEL -I{} \
  curl -s -o /dev/null -w "%{http_code} " "$ALB/raft/check?user=$USER" > "$TMP"
echo ""

echo ""
echo "Response code counts:"
tr ' ' '\n' < "$TMP" | grep -v '^$' | sort | uniq -c

rm -f "$TMP"
