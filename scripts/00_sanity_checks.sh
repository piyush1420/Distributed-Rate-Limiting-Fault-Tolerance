#!/bin/bash
#
# 00_sanity_checks.sh
#
# Quick health check of the whole AWS deployment.
# Confirms Redis side, Raft side, and ALB target groups are healthy.
# Run this after `terraform apply` to verify everything came up cleanly.
#
# Usage:
#   ./scripts/00_sanity_checks.sh
#
# Expected: all checks pass with HTTP 200 and healthy target groups.

set -euo pipefail

ALB=http://redisvraft-alb-1752746576.us-east-1.elb.amazonaws.com

echo "=============================================="
echo "SANITY 1: Redis side — basic /check works"
echo "=============================================="
curl -s -w "\nHTTP %{http_code}\n" "$ALB/check?user=SanityRedis"
echo ""

echo "=============================================="
echo "SANITY 2: Raft side — basic /check works"
echo "=============================================="
curl -s -w "\nHTTP %{http_code}\n" "$ALB/raft/check?user=SanityRaft"
echo ""

echo "=============================================="
echo "SANITY 3: ALB target health for both services"
echo "=============================================="
for TG in redisvraft-redis-tg redisvraft-raft-api-tg; do
  echo "--- $TG ---"
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" --query "TargetGroups[0].TargetGroupArn" --output text)
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "TargetHealthDescriptions[*].[Target.Id, TargetHealth.State]" \
    --output table
done

echo ""
echo "=============================================="
echo "SANITY 4: Raft cluster state"
echo "   known_leader must be non-empty"
echo "=============================================="
curl -s "$ALB/raft/status" | python3 -m json.tool
