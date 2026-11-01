package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sync"
	"time"

	"github.com/hashicorp/raft"
)

// TokenBucket tracks one user's rate limit state.
// Tokens is float64 so we can accumulate fractional tokens between requests,
// giving the same smooth continuous-refill semantics as the Redis Lua script.
type TokenBucket struct {
	Tokens     float64   `json:"tokens"`
	LastRefill time.Time `json:"last_refill"`
}

// Command is what gets written to the Raft log
type Command struct {
	Op   string `json:"op"`
	User string `json:"user"`
}

// CheckResult is returned after processing a rate limit check
type CheckResult struct {
	Allowed   bool    `json:"allowed"`
	Remaining float64 `json:"remaining"`
	User      string  `json:"user"`
}

// RateLimiterFSM is the state machine that Raft replicates.
// It implements a continuous token bucket: tokens accumulate at fillRate
// per second up to maxTokens, identical to the Redis Lua script.
type RateLimiterFSM struct {
	mu        sync.RWMutex
	buckets   map[string]*TokenBucket
	maxTokens float64
	fillRate  float64 // tokens per second

	// Metrics for experiments
	totalApplied int64
	lastApplyUs  int64
}

func NewFSM(maxTokens, refillRate, windowSecs int) *RateLimiterFSM {
	// Convert legacy fixed-window params to continuous fill rate:
	// refillRate tokens per windowSecs seconds → tokens/second
	fillRate := float64(refillRate) / float64(windowSecs)
	return &RateLimiterFSM{
		buckets:   make(map[string]*TokenBucket),
		maxTokens: float64(maxTokens),
		fillRate:  fillRate,
	}
}

// Apply is called by Raft when a log entry is committed on majority
func (f *RateLimiterFSM) Apply(log *raft.Log) interface{} {
	start := time.Now()

	var cmd Command
	if err := json.Unmarshal(log.Data, &cmd); err != nil {
		return fmt.Errorf("unmarshal failed: %v", err)
	}

	var result interface{}
	switch cmd.Op {
	case "check":
		result = f.applyCheck(cmd.User)
	default:
		result = fmt.Errorf("unknown op: %s", cmd.Op)
	}

	f.mu.Lock()
	f.totalApplied++
	f.lastApplyUs = time.Since(start).Microseconds()
	f.mu.Unlock()

	return result
}

// applyCheck is the core continuous token bucket logic.
// Tokens accumulate proportionally to elapsed time (same as the Redis Lua script),
// so both limiters behave identically under the same load profile.
func (f *RateLimiterFSM) applyCheck(user string) *CheckResult {
	f.mu.Lock()
	defer f.mu.Unlock()

	now := time.Now()

	bucket, exists := f.buckets[user]
	if !exists {
		bucket = &TokenBucket{Tokens: f.maxTokens, LastRefill: now}
		f.buckets[user] = bucket
	}

	// Continuous refill: add tokens proportional to elapsed seconds
	elapsed := now.Sub(bucket.LastRefill).Seconds()
	bucket.Tokens = math.Min(f.maxTokens, bucket.Tokens+elapsed*f.fillRate)
	bucket.LastRefill = now

	if bucket.Tokens >= 1 {
		bucket.Tokens--
		return &CheckResult{Allowed: true, Remaining: bucket.Tokens, User: user}
	}
	return &CheckResult{Allowed: false, Remaining: bucket.Tokens, User: user}
}

// GetBucket returns a user's current state (read only, no Raft)
func (f *RateLimiterFSM) GetBucket(user string) *TokenBucket {
	f.mu.RLock()
	defer f.mu.RUnlock()

	b, exists := f.buckets[user]
	if !exists {
		return &TokenBucket{Tokens: f.maxTokens, LastRefill: time.Now()}
	}
	return &TokenBucket{Tokens: b.Tokens, LastRefill: b.LastRefill}
}

// Stats returns metrics for monitoring and experiments
func (f *RateLimiterFSM) Stats() map[string]interface{} {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return map[string]interface{}{
		"total_users":   len(f.buckets),
		"total_applied": f.totalApplied,
		"last_apply_us": f.lastApplyUs,
		"max_tokens":    f.maxTokens,
		"fill_rate":     f.fillRate,
	}
}

// Snapshot saves current state for log compaction
func (f *RateLimiterFSM) Snapshot() (raft.FSMSnapshot, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	clone := make(map[string]*TokenBucket)
	for k, v := range f.buckets {
		clone[k] = &TokenBucket{Tokens: v.Tokens, LastRefill: v.LastRefill}
	}
	return &fsmSnapshot{buckets: clone}, nil
}

// Restore loads state from a snapshot
func (f *RateLimiterFSM) Restore(rc io.ReadCloser) error {
	defer rc.Close()
	var buckets map[string]*TokenBucket
	if err := json.NewDecoder(rc).Decode(&buckets); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.buckets = buckets
	return nil
}

type fsmSnapshot struct {
	buckets map[string]*TokenBucket
}

func (s *fsmSnapshot) Persist(sink raft.SnapshotSink) error {
	data, err := json.Marshal(s.buckets)
	if err != nil {
		sink.Cancel()
		return err
	}
	if _, err := sink.Write(data); err != nil {
		sink.Cancel()
		return err
	}
	return sink.Close()
}

func (s *fsmSnapshot) Release() {}
