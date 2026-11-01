#!/bin/bash
set -euo pipefail

# Install Docker and CloudWatch agent
dnf update -y
dnf install -y docker amazon-cloudwatch-agent
systemctl enable --now docker

# Give ec2-user docker access
usermod -aG docker ec2-user

# ── CloudWatch log config ─────────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CW'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [{
          "file_path": "/var/log/raft-node.log",
          "log_group_name": "${log_group}",
          "log_stream_name": "${node_id}",
          "timezone": "UTC"
        }]
      }
    }
  }
}
CW
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# ── ECR login ─────────────────────────────────────────────────────────────────

# aws ecr get-login-password --region ${region} | \
#   docker login --username AWS --password-stdin \
#   $(echo "${ecr_image}" | cut -d/ -f1)

echo "Using public image: ${ecr_image}"
# ── Pull image (retry until ECR image is pushed) ──────────────────────────────
for i in $(seq 1 20); do
  docker pull ${ecr_image} && break
  echo "Attempt $i: image not ready yet, retrying in 30s..."
  sleep 30
done

# ── Run Raft node ─────────────────────────────────────────────────────────────
# JOIN_ADDR is intentionally always passed; Go binary ignores it when empty.
# --network host: Raft binds to the EC2 private IP directly (e.g. 10.0.0.10:7000).
# Bridge networking won't work because the container can't bind to the host's private IP.
docker run -d \
  --name raft-node \
  --restart always \
  --network host \
  -v /data:/data \
  -e NODE_ID="${node_id}" \
  -e RAFT_ADDR="${raft_addr}" \
  -e HTTP_ADDR="${http_addr}" \
  -e DATA_DIR=/data \
  -e BOOTSTRAP="${bootstrap}" \
  -e JOIN_ADDR="${join_addr}" \
  -e MAX_TOKENS="${max_tokens}" \
  -e WINDOW_SECS="${window_secs}" \
  -e HEARTBEAT_MS="${heartbeat_ms}" \
  -e ELECTION_MS="${election_ms}" \
  "${ecr_image}" 2>&1 | tee -a /var/log/raft-node.log
