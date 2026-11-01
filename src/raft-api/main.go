package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

// CheckResponse is the shape of /check responses returned to clients.
// Matches the raft-limiter and redis-limiter contract.
type CheckResponse struct {
	Allowed   bool    `json:"allowed"`
	Remaining float64 `json:"remaining"`
	User      string  `json:"user"`
	Source    string  `json:"source"` // "cache" or "raft" — for observability
}

func main() {
	// -------------------------------------------------------
	// Parse config from env vars
	// -------------------------------------------------------
	raftNodes := getEnv("RAFT_NODES", "raft-node1:8000,raft-node2:8000,raft-node3:8000")
	cacheTTLSecs := getEnvInt("CACHE_TTL_SECS", 1)
	httpAddr := getEnv("HTTP_ADDR", "0.0.0.0:8000")

	log.Printf("Starting raft-api (raft_nodes=%s cache_ttl=%ds http=%s)",
		raftNodes, cacheTTLSecs, httpAddr)

	// -------------------------------------------------------
	// Wire up cache + leader discovery
	// -------------------------------------------------------
	cache := NewCache(time.Duration(cacheTTLSecs) * time.Second)
	leaderDisco := NewLeaderDiscovery(raftNodes)

	// -------------------------------------------------------
	// Set up Gin router
	// -------------------------------------------------------
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())

	// Handler factory so we can share the same logic on both / and /raft/
	checkHandler := func(c *gin.Context) {
		user := c.Query("user")
		if user == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "user parameter is required"})
			return
		}

		// Cache hit path: serve locally
		if entry, ok := cache.Get(user); ok {
			if !entry.Allowed {
				c.JSON(http.StatusTooManyRequests, CheckResponse{
					Allowed:   false,
					Remaining: entry.Remaining,
					User:      user,
					Source:    "cache",
				})
				return
			}
			// Decrement the cached count so repeated cache hits converge correctly
			cache.Decrement(user)
			updated, _ := cache.Get(user)
			c.JSON(http.StatusOK, CheckResponse{
				Allowed:   true,
				Remaining: updated.Remaining,
				User:      user,
				Source:    "cache",
			})
			return
		}

		// Cache miss path: forward to Raft leader
		result, err := ForwardToRaft(leaderDisco, user)
		if err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error": fmt.Sprintf("raft unavailable: %v", err),
			})
			return
		}

		// Parse leader response so we can cache it and return a shaped payload
		var raftResp struct {
			Allowed   bool    `json:"allowed"`
			Remaining float64 `json:"remaining"`
			User      string  `json:"user"`
		}
		if err := json.Unmarshal(result.Body, &raftResp); err != nil {
			// Couldn't parse — relay raw body and status as-is
			c.Data(result.StatusCode, "application/json", result.Body)
			return
		}

		// Cache the fresh decision for future requests
		cache.Set(user, raftResp.Allowed, raftResp.Remaining)

		status := http.StatusOK
		if !raftResp.Allowed {
			status = http.StatusTooManyRequests
		}
		c.JSON(status, CheckResponse{
			Allowed:   raftResp.Allowed,
			Remaining: raftResp.Remaining,
			User:      user,
			Source:    "raft",
		})
	}

	// Handler factory for /debug/per-node — queries each Raft node's /status
	// directly and reports whether they're in sync. If ?user=X is provided,
	// per-user token state is also included from each node.
	debugPerNodeHandler := func(c *gin.Context) {
		user := c.Query("user") // optional

		nodes := leaderDisco.Nodes()
		snapshots := FetchAllNodeStatus(nodes, user)

		// Check whether all reachable nodes agree on commit_index and applied_index
		inSync := true
		var commitRef, appliedRef interface{}
		refSet := false
		for _, snap := range snapshots {
			if !snap.Reachable {
				inSync = false
				continue
			}
			thisCommit := snap.RaftStatus["commit_index"]
			thisApplied := snap.RaftStatus["applied_index"]
			if !refSet {
				commitRef, appliedRef = thisCommit, thisApplied
				refSet = true
				continue
			}
			if thisCommit != commitRef || thisApplied != appliedRef {
				inSync = false
			}
		}

		c.JSON(http.StatusOK, gin.H{
			"user":       user,
			"in_sync":    inSync,
			"node_count": len(snapshots),
			"nodes":      snapshots,
		})
	}

	// Root paths — also used for direct access in local testing
	router.GET("/check", checkHandler)
	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	router.GET("/status", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"service":      "raft-api",
			"known_leader": leaderDisco.Leader(),
			"known_nodes":  leaderDisco.Nodes(),
			"cache":        cache.Stats(),
		})
	})
	router.GET("/debug/per-node", debugPerNodeHandler)

	// /raft prefix — for ALB path-based routing
	raftGroup := router.Group("/raft")
	{
		raftGroup.GET("/check", checkHandler)
		raftGroup.GET("/health", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{"status": "ok"})
		})
		raftGroup.GET("/status", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{
				"service":      "raft-api",
				"known_leader": leaderDisco.Leader(),
				"known_nodes":  leaderDisco.Nodes(),
				"cache":        cache.Stats(),
			})
		})
		raftGroup.GET("/debug/per-node", debugPerNodeHandler)
	}

	log.Printf("HTTP server listening on %s", httpAddr)
	if err := router.Run(httpAddr); err != nil {
		log.Fatalf("HTTP server failed: %v", err)
	}
}

// Helper functions
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}