# ── Raft cluster on EC2 ───────────────────────────────────────────────────────
#
# Cloud Map (servicediscovery) is blocked in AWS Academy (voclabs role).
# Solution: assign fixed private IPs to EC2 instances at launch. The IPs are
# stable for the lifetime of the instance, so Raft peers can address each other
# directly without any DNS discovery service.
#
#   node1  10.0.0.10  (bootstrap)
#   node2  10.0.0.11  (joins node1)
#   node3  10.0.0.12  (joins node1)
#
# All three nodes sit in the same /24 public subnet. The ALB registers them
# via aws_lb_target_group_attachment using their instance IDs.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_iam_instance_profile" "raft" {
  name = "${var.project}-raft-instance-profile"
  role = data.aws_iam_role.lab_role.name
}

resource "aws_cloudwatch_log_group" "raft_limiter" {
  name              = "/ec2/${var.project}/raft-limiter"
  retention_in_days = 7
}

# ── node1 (bootstrap) ─────────────────────────────────────────────────────────

resource "aws_instance" "raft_node1" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = "10.0.0.10"
  vpc_security_group_ids      = [aws_security_group.raft.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.raft.name
  key_name = "redisvraft-piyush-sshkey"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }
  user_data = base64encode(templatefile("${path.module}/userdata_raft.sh.tpl", {
    region       = var.aws_region
    ecr_image    = "public.ecr.aws/d0v7o8n5/redisvraft-piyush-raft-limiter:latest"
    node_id      = "node1"
    raft_addr    = "10.0.0.10:7000"
    http_addr    = "0.0.0.0:8000"
    bootstrap    = "true"
    join_addr    = ""
    max_tokens   = var.raft_max_tokens
    window_secs  = var.raft_window_secs
    heartbeat_ms = var.raft_heartbeat_ms
    election_ms  = var.raft_election_ms
    log_group    = "/ec2/${var.project}/raft-limiter"
  }))

  tags = { Name = "${var.project}-raft-node1" }
}

# ── node2 ─────────────────────────────────────────────────────────────────────

resource "aws_instance" "raft_node2" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = "10.0.0.11"
  vpc_security_group_ids      = [aws_security_group.raft.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.raft.name
  key_name = "redisvraft-piyush-sshkey"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }
  user_data = base64encode(templatefile("${path.module}/userdata_raft.sh.tpl", {
    region       = var.aws_region
    ecr_image    = "public.ecr.aws/d0v7o8n5/redisvraft-piyush-raft-limiter:latest"
    node_id      = "node2"
    raft_addr    = "10.0.0.11:7000"
    http_addr    = "0.0.0.0:8000"
    bootstrap    = "false"
    join_addr    = "10.0.0.10:8000"
    max_tokens   = var.raft_max_tokens
    window_secs  = var.raft_window_secs
    heartbeat_ms = var.raft_heartbeat_ms
    election_ms  = var.raft_election_ms
    log_group    = "/ec2/${var.project}/raft-limiter"
  }))

  tags = { Name = "${var.project}-raft-node2" }

  # node2 waits for node1 to be running before joining
  depends_on = [aws_instance.raft_node1]
}

# ── node3 ─────────────────────────────────────────────────────────────────────

resource "aws_instance" "raft_node3" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = "10.0.0.12"
  vpc_security_group_ids      = [aws_security_group.raft.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.raft.name
  key_name = "redisvraft-piyush-sshkey"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }
  user_data = base64encode(templatefile("${path.module}/userdata_raft.sh.tpl", {
    region       = var.aws_region
    ecr_image    = "public.ecr.aws/d0v7o8n5/redisvraft-piyush-raft-limiter:latest"
    node_id      = "node3"
    raft_addr    = "10.0.0.12:7000"
    http_addr    = "0.0.0.0:8000"
    bootstrap    = "false"
    join_addr    = "10.0.0.10:8000"
    max_tokens   = var.raft_max_tokens
    window_secs  = var.raft_window_secs
    heartbeat_ms = var.raft_heartbeat_ms
    election_ms  = var.raft_election_ms
    log_group    = "/ec2/${var.project}/raft-limiter"
  }))

  tags = { Name = "${var.project}-raft-node3" }

  depends_on = [aws_instance.raft_node1]
}

# ── Register all 3 nodes with the ALB target group ───────────────────────────

resource "aws_lb_target_group_attachment" "raft_node1" {
  target_group_arn = aws_lb_target_group.raft_limiter.arn
  target_id        = aws_instance.raft_node1.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "raft_node2" {
  target_group_arn = aws_lb_target_group.raft_limiter.arn
  target_id        = aws_instance.raft_node2.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "raft_node3" {
  target_group_arn = aws_lb_target_group.raft_limiter.arn
  target_id        = aws_instance.raft_node3.id
  port             = 8000
}





