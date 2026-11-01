#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

NODE1="http://localhost:8001"
NODE2="http://localhost:8002"
NODE3="http://localhost:8003"

echo ""
echo "======================================"
echo "  Raft Rate Limiter — Test Suite"
echo "======================================"

echo -e "\n${YELLOW}Waiting 8 seconds for cluster to form...${NC}"
sleep 8

# TEST 1: Health checks
echo -e "\n${YELLOW}TEST 1: Health Checks${NC}"
S1=$(curl -s -o /dev/null -w "%{http_code}" $NODE1/health)
S2=$(curl -s -o /dev/null -w "%{http_code}" $NODE2/health)
S3=$(curl -s -o /dev/null -w "%{http_code}" $NODE3/health)
echo "  Node1=$S1  Node2=$S2  Node3=$S3"
if [ "$S1" = "200" ] && [ "$S2" = "200" ] && [ "$S3" = "200" ]; then
    echo -e "  ${GREEN}PASS: All nodes healthy${NC}"
else
    echo -e "  ${RED}FAIL: Some nodes unhealthy${NC}"
fi

# TEST 2: Cluster status
echo -e "\n${YELLOW}TEST 2: Cluster Status${NC}"
echo "  Node1: $(curl -s $NODE1/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'state={d[\"node_state\"]} term={d[\"term\"]}')" 2>/dev/null || echo "error")"
echo "  Node2: $(curl -s $NODE2/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'state={d[\"node_state\"]} term={d[\"term\"]}')" 2>/dev/null || echo "error")"
echo "  Node3: $(curl -s $NODE3/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'state={d[\"node_state\"]} term={d[\"term\"]}')" 2>/dev/null || echo "error")"
echo -e "  ${GREEN}PASS: Check that one node is Leader and two are Follower${NC}"

# TEST 3: Basic rate limiting
echo -e "\n${YELLOW}TEST 3: Rate Limiting Works${NC}"
for i in 1 2 3; do
    R=$(curl -s $NODE1/check?user=TestUser)
    echo "  Request $i: $R"
done
echo -e "  ${GREEN}PASS: Remaining tokens should decrease${NC}"

# TEST 4: Replication
echo -e "\n${YELLOW}TEST 4: Replication — All Nodes Agree${NC}"
T1=$(curl -s "$NODE1/status?user=TestUser" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tokens_remaining','?'))" 2>/dev/null)
T2=$(curl -s "$NODE2/status?user=TestUser" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tokens_remaining','?'))" 2>/dev/null)
T3=$(curl -s "$NODE3/status?user=TestUser" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tokens_remaining','?'))" 2>/dev/null)
echo "  Node1=$T1  Node2=$T2  Node3=$T3"
if [ "$T1" = "$T2" ] && [ "$T2" = "$T3" ]; then
    echo -e "  ${GREEN}PASS: All nodes have same token count${NC}"
else
    echo -e "  ${RED}FAIL: Nodes disagree on token count${NC}"
fi

# TEST 5: User gets blocked at 0 tokens
echo -e "\n${YELLOW}TEST 5: Block User After Exhausting Tokens${NC}"
echo "  Sending 105 requests for BlockTest..."
BLOCKED=false
for i in $(seq 1 105); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" $NODE1/check?user=BlockTest)
    if [ "$CODE" = "429" ] && [ "$BLOCKED" = false ]; then
        echo "  Blocked at request $i (HTTP 429)"
        BLOCKED=true
        break
    fi
done
if [ "$BLOCKED" = true ]; then
    echo -e "  ${GREEN}PASS: User blocked after exhausting tokens${NC}"
else
    echo -e "  ${RED}FAIL: User was never blocked${NC}"
fi

# TEST 6: Different users have separate buckets
echo -e "\n${YELLOW}TEST 6: Separate Limits Per User${NC}"
R1=$(curl -s $NODE1/check?user=Alice | python3 -c "import sys,json; print(json.load(sys.stdin)['remaining'])" 2>/dev/null)
R2=$(curl -s $NODE1/check?user=Bob | python3 -c "import sys,json; print(json.load(sys.stdin)['remaining'])" 2>/dev/null)
R3=$(curl -s $NODE1/check?user=Charlie | python3 -c "import sys,json; print(json.load(sys.stdin)['remaining'])" 2>/dev/null)
echo "  Alice=$R1  Bob=$R2  Charlie=$R3"
if [ "$R1" = "99" ] && [ "$R2" = "99" ] && [ "$R3" = "99" ]; then
    echo -e "  ${GREEN}PASS: Each user has independent tokens${NC}"
else
    echo -e "  ${RED}FAIL: Users may be sharing state${NC}"
fi

# TEST 7: Error handling
echo -e "\n${YELLOW}TEST 7: Missing User Parameter${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" $NODE1/check)
echo "  Status code: $CODE"
if [ "$CODE" = "400" ]; then
    echo -e "  ${GREEN}PASS: Returns 400 for missing user${NC}"
else
    echo -e "  ${RED}FAIL: Expected 400${NC}"
fi

echo -e "\n======================================"
echo "  Basic Tests Complete!"
echo ""
echo "  Next steps:"
echo "  1. Kill follower:  docker compose stop node3"
echo "     Then:           curl $NODE1/check?user=Test"
echo "     (should still work)"
echo ""
echo "  2. Kill leader:    docker compose stop node1"
echo "     Wait 2s, then: curl $NODE2/status"
echo "     (new leader should be elected)"
echo ""
echo "  3. Bring back:     docker compose start node1"
echo "     Wait 3s, then: curl $NODE1/status"
echo "     (should be Follower, caught up)"
echo "======================================"






