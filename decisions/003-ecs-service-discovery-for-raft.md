# ADR 003 — EC2 with fixed private IPs for Raft peer addressing

**Date:** 2026-04-18  
**Status:** Superseded — Cloud Map blocked; EC2 fixed IPs adopted (see below)

## Decision

Each Raft node is registered with **AWS Cloud Map** under a private DNS namespace (`raft.local`). Nodes address each other via stable DNS names (`node1.raft.local`, `node2.raft.local`, `node3.raft.local`) rather than IPs.

## Context

Raft requires every node to know the stable address of every peer at startup — for bootstrap, join, and re-join after leader election. On ECS Fargate, task private IPs are ephemeral: they change on every task replacement or redeployment. Hardcoded IPs in task definitions would break the cluster silently whenever a task restarts.

## Alternatives rejected

- **Hardcoded private IPs via reserved ENIs** — possible but requires pre-allocating ENIs and wiring them to tasks; significant operational overhead and not supported natively by Fargate.
- **Store peer IPs in SSM Parameter Store, poll at startup** — works but requires a custom bootstrap script, IAM permissions for SSM reads, and a retry loop with no guarantee of consistency during simultaneous restarts.
- **Single-node Raft (no cluster)** — defeats the purpose of the experiment; Raft's consensus cost only shows at quorum.

## Consequences (original Cloud Map plan)

- `RAFT_ADDR` and `JOIN_ADDR` env vars in ECS task definitions use Cloud Map DNS names, not IPs.
- Cloud Map health checks must be disabled or set to `CUSTOM`.

---

## Revision — Cloud Map blocked in AWS Academy

`servicediscovery:CreatePrivateDnsNamespace` is not permitted under the `voclabs` IAM role used by AWS Academy.

**Adopted solution:** EC2 instances (`t3.micro`) with manually assigned private IPs at launch time. The IPs are stable for the lifetime of the instance — no DNS discovery needed.

```
node1  10.0.0.10  (BOOTSTRAP=true)
node2  10.0.0.11  (JOIN_ADDR=10.0.0.10:8000)
node3  10.0.0.12  (JOIN_ADDR=10.0.0.10:8000)
```

EC2 user data pulls the image from ECR and starts the container with hardcoded peer IPs. The ALB registers the instances via `aws_lb_target_group_attachment` using `instance` target type (not `ip`).

**Trade-off:** If a node is terminated and replaced, it gets a new instance ID but Terraform re-applies the same private IP. The node re-joins using the same `JOIN_ADDR`. This is acceptable for a benchmark environment.
