# ADR 004 — Run Locust locally, not from a dedicated EC2 instance

**Date:** 2026-04-18  
**Status:** Accepted

## Decision

Locust load tests are run from a local machine against the AWS ALB endpoint, not from an EC2 instance co-located in the same VPC.

## Context

Running Locust from EC2 in the same region/VPC eliminates internet latency from measurements, giving cleaner absolute latency numbers. However this project's goal is a **relative comparison** (Redis vs Raft), not production SLA validation.

## Alternatives rejected

- **EC2 in same VPC as ALB** — adds ~$10–20/month, requires SSH key management, and adds setup time. Justified only if absolute latency numbers matter.
- **Locust on ECS/Fargate** — possible but complex (master/worker coordination); overkill for a research benchmark.

## Consequences

- All latency measurements include local → AWS round-trip (~20–80ms depending on region and ISP). This offset is **constant across both test runs** (Redis and Raft use the same ALB), so the relative difference between the two is still valid.
- To reproduce results, tests should be run from the same machine and network. Document the region and rough RTT to ALB in the results notes.
- If absolute latency becomes important in a future milestone, revisit this decision and spin up a t3.small Locust driver in the same AZ as the ECS tasks.
