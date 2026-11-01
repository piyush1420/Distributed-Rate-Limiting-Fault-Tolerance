package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// LeaderDiscovery periodically polls all known Raft nodes to find the current
// leader. This avoids forwarding to a dead node or a stale leader address.
type LeaderDiscovery struct {
	mu          sync.RWMutex
	nodes       []string // HTTP addresses of all Raft nodes, e.g. ["10.0.0.10:8000", ...]
	leaderAddr  string   // HTTP address of the current leader (if known)
	pollInterval time.Duration
}

// NewLeaderDiscovery takes a comma-separated list of Raft node HTTP addresses
// and starts a background goroutine that refreshes the leader every 5 seconds.
func NewLeaderDiscovery(nodesCSV string) *LeaderDiscovery {
	nodes := []string{}
	for _, n := range strings.Split(nodesCSV, ",") {
		if s := strings.TrimSpace(n); s != "" {
			nodes = append(nodes, s)
		}
	}
	ld := &LeaderDiscovery{
		nodes:        nodes,
		pollInterval: 5 * time.Second,
	}
	// Do an initial discovery synchronously so the first request has a leader
	ld.refresh()
	go ld.discoverLoop()
	return ld
}

// Leader returns the currently known leader HTTP address, or "" if unknown.
func (ld *LeaderDiscovery) Leader() string {
	ld.mu.RLock()
	defer ld.mu.RUnlock()
	return ld.leaderAddr
}

// Nodes returns the full list of known Raft nodes (for fallback forwarding).
func (ld *LeaderDiscovery) Nodes() []string {
	ld.mu.RLock()
	defer ld.mu.RUnlock()
	out := make([]string, len(ld.nodes))
	copy(out, ld.nodes)
	return out
}

// discoverLoop polls all nodes periodically and updates the known leader.
func (ld *LeaderDiscovery) discoverLoop() {
	ticker := time.NewTicker(ld.pollInterval)
	defer ticker.Stop()
	for range ticker.C {
		ld.refresh()
	}
}

// refresh asks each known node "who's the leader?" and updates the cache.
// Uses /status which returns JSON containing leader_addr.
func (ld *LeaderDiscovery) refresh() {
	client := &http.Client{Timeout: 2 * time.Second}

	for _, node := range ld.nodes {
		resp, err := client.Get(fmt.Sprintf("http://%s/status", node))
		if err != nil {
			continue
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			continue
		}

		var status struct {
			LeaderAddr string `json:"leader_addr"`
		}
		if err := json.Unmarshal(body, &status); err != nil {
			continue
		}

		// leader_addr from raft-limiter is in format "host:7000" (Raft peer port).
		// Convert to HTTP port 8000.
		if status.LeaderAddr != "" {
			httpAddr := raftAddrToHTTP(status.LeaderAddr)
			ld.mu.Lock()
			ld.leaderAddr = httpAddr
			ld.mu.Unlock()
			return
		}
	}
	log.Printf("leader discovery: no node reported a leader")
}

// raftAddrToHTTP turns "10.0.0.10:7000" into "10.0.0.10:8000".
func raftAddrToHTTP(raftAddr string) string {
	if idx := strings.LastIndex(raftAddr, ":"); idx >= 0 {
		return raftAddr[:idx] + ":8000"
	}
	return raftAddr + ":8000"
}

// ForwardResult is what we return from a Raft forward call.
type ForwardResult struct {
	StatusCode int
	Body       []byte
}

// ForwardToRaft sends a /check request to the current leader and returns
// the raw response. On failure, retries once with a fresh leader discovery.
func ForwardToRaft(ld *LeaderDiscovery, user string) (*ForwardResult, error) {
	client := &http.Client{Timeout: 5 * time.Second}

	for attempt := 0; attempt < 2; attempt++ {
		leader := ld.Leader()
		if leader == "" {
			// No leader known — refresh and retry
			ld.refresh()
			time.Sleep(200 * time.Millisecond)
			continue
		}

		url := fmt.Sprintf("http://%s/check?user=%s", leader, user)
		resp, err := client.Get(url)
		if err != nil {
			// Leader might be dead — re-discover for next attempt
			ld.refresh()
			time.Sleep(200 * time.Millisecond)
			continue
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			continue
		}

		return &ForwardResult{
			StatusCode: resp.StatusCode,
			Body:       body,
		}, nil
	}

	return nil, fmt.Errorf("forward failed: no leader available after retries")
}

// ─────────────────────────────────────────────────────────────────────────────
// FetchAllNodeStatus queries every known Raft node's /status endpoint directly
// and returns their individual states side-by-side. Used by the /debug/per-node
// endpoint to verify cluster synchronization (especially after failover).
//
// If a user parameter is supplied, the per-user token count is also included
// from each node's response.
// ─────────────────────────────────────────────────────────────────────────────

type NodeSnapshot struct {
	Address    string                 `json:"address"`
	Reachable  bool                   `json:"reachable"`
	Error      string                 `json:"error,omitempty"`
	RaftStatus map[string]interface{} `json:"raft_status,omitempty"`
}

func FetchAllNodeStatus(nodeAddrs []string, user string) []NodeSnapshot {
	snapshots := make([]NodeSnapshot, 0, len(nodeAddrs))
	client := &http.Client{Timeout: 2 * time.Second}

	for _, addr := range nodeAddrs {
		snap := NodeSnapshot{Address: addr}

		url := fmt.Sprintf("http://%s/status", addr)
		if user != "" {
			url = fmt.Sprintf("http://%s/status?user=%s", addr, user)
		}

		resp, err := client.Get(url)
		if err != nil {
			snap.Reachable = false
			snap.Error = err.Error()
			snapshots = append(snapshots, snap)
			continue
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			snap.Reachable = false
			snap.Error = "read body: " + err.Error()
			snapshots = append(snapshots, snap)
			continue
		}

		var parsed map[string]interface{}
		if err := json.Unmarshal(body, &parsed); err != nil {
			snap.Reachable = false
			snap.Error = "parse body: " + err.Error()
			snapshots = append(snapshots, snap)
			continue
		}

		snap.Reachable = true
		snap.RaftStatus = parsed
		snapshots = append(snapshots, snap)
	}

	return snapshots
}
