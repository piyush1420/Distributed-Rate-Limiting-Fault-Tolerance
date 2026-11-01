package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hashicorp/raft"
)

// SetupRouter creates and configures the Gin router with all endpoints
func SetupRouter(r *raft.Raft, f *RateLimiterFSM) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.Use(RequestLogger())

	h := &Handlers{raft: r, fsm: f}

	// Root routes — for direct node access and docker-compose local testing
	router.GET("/check", h.Check)
	router.GET("/status", h.Status)
	router.GET("/health", h.Health)
	router.POST("/join", h.Join)

	// /raft prefix group — for ALB path-based routing on port 80.
	// ALB forwards the full path unchanged, so /raft/check arrives here as-is.
	raftGroup := router.Group("/raft")
	{
		raftGroup.GET("/check", h.Check)
		raftGroup.GET("/status", h.Status)
		raftGroup.GET("/health", h.Health)
	}

	return router
}

// RequestLogger is middleware that logs request latency (useful for experiments)
func RequestLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		latency := time.Since(start)
		fmt.Printf("[%s] %s %s | %d | %v\n",
			time.Now().Format("15:04:05"),
			c.Request.Method,
			c.Request.URL.Path,
			c.Writer.Status(),
			latency,
		)
	}
}

type Handlers struct {
	raft *raft.Raft
	fsm  *RateLimiterFSM
}

// raftAddrToHTTP converts a Raft peer address like "10.0.0.10:7000" or "node1:7000"
// into the HTTP API address on the same host, which always runs on port 8000.
// This is needed because raft.LeaderWithID() returns the Raft transport address,
// but forwards must go to the HTTP endpoint.
func raftAddrToHTTP(raftAddr string) string {
	if idx := strings.LastIndex(raftAddr, ":"); idx >= 0 {
		return raftAddr[:idx] + ":8000"
	}
	// No port in address (shouldn't happen, but be safe)
	return raftAddr + ":8000"
}

// forwardToLeader makes an HTTP GET to the leader's /check endpoint and returns
// the status code and body. Followers call this to transparently proxy requests
// to the leader instead of sending an HTTP redirect back to the client.
func forwardToLeader(leaderHTTPAddr, user string) (int, []byte, error) {
	url := fmt.Sprintf("http://%s/check?user=%s", leaderHTTPAddr, user)

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, body, nil
}

// GET /check?user=User123
// The main rate limiting endpoint.
// On the leader: goes through Raft consensus and returns the result.
// On a follower: forwards the request to the leader's HTTP endpoint and relays
// the response back to the client (no client-visible redirect).
func (h *Handlers) Check(c *gin.Context) {
	user := c.Query("user")
	if user == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user parameter is required"})
		return
	}


	// Followers forward to the leader instead of redirecting.
	// This keeps client-side code simple and works across NAT / private networks
	// where the client can reach the ALB but not the leader's private IP directly.

	if h.raft.State() != raft.Leader {
		leaderAddr, _ := h.raft.LeaderWithID()
		if leaderAddr == "" {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error": "no leader available, election in progress",
			})
			return
		}

		leaderHTTP := raftAddrToHTTP(string(leaderAddr))

		// One short retry in case the leader just changed and we caught a transient error
		var status int
		var body []byte
		var err error
		for attempt := 0; attempt < 2; attempt++ {
			status, body, err = forwardToLeader(leaderHTTP, user)
			if err == nil {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}

		if err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error": fmt.Sprintf("failed to forward to leader: %v", err),
			})
			return
		}

		// Relay the leader's response verbatim
		c.Data(status, "application/json", body)

		// leaderAddr is the Raft transport addr (host:7000); HTTP is on :8000
		httpAddr := strings.Replace(string(leaderAddr), ":7000", ":8000", 1)
		proxyURL := fmt.Sprintf("http://%s%s?user=%s", httpAddr, c.FullPath(), user)
		resp, err := http.Get(proxyURL)
		if err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": fmt.Sprintf("leader proxy failed: %v", err)})
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		c.Data(resp.StatusCode, "application/json", body)

		return
	}

	// This node is the leader — process through Raft consensus
	cmd := Command{Op: "check", User: user}
	data, _ := json.Marshal(cmd)

	// raft.Apply sends the command to the log, waits for majority to confirm,
	// then returns the result.
	future := h.raft.Apply(data, 5*time.Second)
	if err := future.Error(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("raft apply failed: %v", err),
		})
		return
	}

	result := future.Response()
	resp, ok := result.(*CheckResult)
	if !ok {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("unexpected fsm response type: %T", result),
		})
		return
	}

	if !resp.Allowed {
		c.JSON(http.StatusTooManyRequests, resp)
		return
	}
	c.JSON(http.StatusOK, resp)
}

// GET /status?user=<optional>
// Returns cluster state plus optional user bucket info (local read, no Raft)
func (h *Handlers) Status(c *gin.Context) {
	leaderAddr, leaderID := h.raft.LeaderWithID()
	stats := h.fsm.Stats()

	body := gin.H{
		"node_state":     h.raft.State().String(),
		"leader_addr":    string(leaderAddr),
		"leader_id":      string(leaderID),
		"last_index":     h.raft.LastIndex(),
		"applied_index":  h.raft.AppliedIndex(),
		"fsm":            stats,
	}

	if user := c.Query("user"); user != "" {
		bucket := h.fsm.GetBucket(user)
		body["user"] = user
		body["bucket"] = bucket
	}

	c.JSON(http.StatusOK, body)
}

// GET /health
// Simple health check for ALB
func (h *Handlers) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status": "ok",
		"state":  h.raft.State().String(),
	})
}

// POST /join
// Allows a new node to join the Raft cluster.
// Body: {"node_id": "node2", "raft_addr": "node2:7000"}
func (h *Handlers) Join(c *gin.Context) {
	var req struct {
		NodeID   string `json:"node_id" binding:"required"`
		RaftAddr string `json:"raft_addr" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if h.raft.State() != raft.Leader {
		c.JSON(http.StatusBadRequest, gin.H{"error": "not the leader"})
		return
	}

	future := h.raft.AddVoter(
		raft.ServerID(req.NodeID),
		raft.ServerAddress(req.RaftAddr),
		0, 0,
	)
	if err := future.Error(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("failed to add voter: %v", err),
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"status":  "ok",
		"message": fmt.Sprintf("node %s joined", req.NodeID),
	})
}