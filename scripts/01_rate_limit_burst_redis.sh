#!/bin/bash
#
# 01_rate_limit_burst_redis.sh
#
# Prove Redis side actually enforces the token bucket limit.
# Fires 200 parallel requests for a single user. Bucket is 100 tokens,
# so ~100 requests should return 200 (allowed) and ~100 should return 429 (denied).
#
# Why parallel: sequential curls over the internet take ~50ms each, giving
# the continuous-refill algorithm enough time to top the bucket back up
# between requests. Parallel fires them too fast to refill, forcing drainage.
#
# Usage:
#   ./scripts/01_rate_limit_burst_redis.sh
#
# Expected output (approximate):
#    100 "200"
#    100 "429"

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com
USER="RedisBurst-$(date +%s)"
TOTAL=200
PARALLEL=50
TMP=/tmp/redis_burst_$$.txt

echo "Firing $TOTAL requests for user=$USER ($PARALLEL parallel)..."

seq 1 $TOTAL | xargs -n1 -P$PARALLEL -I{} \
  curl -s -o /dev/null -w "%{http_code} " "$ALB/check?user=$USER" > "$TMP"
echo ""

echo ""
echo "Response code counts:"
tr ' ' '\n' < "$TMP" | grep -v '^$' | sort | uniq -c

rm -f "$TMP"
