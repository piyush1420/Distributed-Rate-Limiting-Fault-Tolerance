# ADR 002 — Continuous token bucket algorithm for both limiters

**Date:** 2026-04-18  
**Status:** Accepted

## Decision

Both limiters implement a **continuous token bucket**: tokens accumulate proportionally to elapsed time (`tokens = min(capacity, tokens + elapsed_seconds × fill_rate)`), not a fixed-window reset.

## Context

The Redis limiter used continuous refill from the start (Lua script). The Raft limiter was independently built with a fixed-window approach (all tokens reset at the end of each `WINDOW_SECS` period). This produced different allow/deny distributions under the same load — spiky burst pattern on Raft, smooth on Redis — making any latency/throughput comparison meaningless.

## Alternatives rejected

- **Fixed-window for both** — simpler, but bursts at window boundaries create artificial spikes that skew Locust latency histograms.
- **Keep different algorithms, document the difference** — valid for a study on algorithm behavior, but this project's goal is to isolate the *consistency mechanism* (Redis single-master vs Raft consensus), not the *algorithm*.

## Consequences

- Raft FSM uses `float64` tokens and updates `LastRefill` on every `Apply()` call.
- `WINDOW_SECS` on the Raft service is still accepted as a config param but is converted to `fill_rate = MAX_TOKENS / WINDOW_SECS` at startup — it no longer controls a reset boundary.
- Under identical config (`MAX_TOKENS=100`, `WINDOW_SECS=60` → `fill_rate=1.67/s`), both limiters will allow/deny at the same rate, so latency and throughput deltas are attributable to the consensus mechanism alone.
