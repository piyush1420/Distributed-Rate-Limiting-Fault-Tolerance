package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hashicorp/raft"
	raftboltdb "github.com/hashicorp/raft-boltdb/v2"
)

func main() {
	// -------------------------------------------------------
	// Parse configuration from flags and env vars
	// -------------------------------------------------------
	nodeID := flag.String("id", getEnv("NODE_ID", ""), "Unique node ID")
	raftAddr := flag.String("raft-addr", getEnv("RAFT_ADDR", "localhost:7000"), "Raft address")
	httpAddr := flag.String("http-addr", getEnv("HTTP_ADDR", "localhost:8000"), "HTTP address")
	joinAddr := flag.String("join", getEnv("JOIN_ADDR", ""), "Leader HTTP address to join")
	dataDir := flag.String("data-dir", getEnv("DATA_DIR", ""), "Data directory")
	bootstrap := flag.Bool("bootstrap", getEnvBool("BOOTSTRAP"), "Bootstrap new cluster")
	maxTokens := flag.Int("max-tokens", getEnvInt("MAX_TOKENS", 100), "Max tokens per user")
	refillRate := flag.Int("refill-rate", getEnvInt("REFILL_RATE", 100), "Tokens refilled per window")
	windowSecs := flag.Int("window-secs", getEnvInt("WINDOW_SECS", 60), "Refill window seconds")
	heartbeatMs := flag.Int("heartbeat-ms", getEnvInt("HEARTBEAT_MS", 1000), "Heartbeat timeout ms")
	electionMs := flag.Int("election-ms", getEnvInt("ELECTION_MS", 1000), "Election timeout ms")
	flag.Parse()

	if *nodeID == "" {
		log.Fatal("--id or NODE_ID is required")
	}
	if *dataDir == "" {
		*dataDir = "/tmp/raft-" + *nodeID
	}

	log.Printf("Starting node %s (raft=%s http=%s data=%s)",
		*nodeID, *raftAddr, *httpAddr, *dataDir)

	// -------------------------------------------------------
	// Create data directory
	// -------------------------------------------------------
	if err := os.MkdirAll(*dataDir, 0755); err != nil {
		log.Fatalf("Failed to create data dir: %v", err)
	}

	// -------------------------------------------------------
	// Create the FSM (token bucket rate limiter)
	// -------------------------------------------------------
	fsm := NewFSM(*maxTokens, *refillRate, *windowSecs)

	// -------------------------------------------------------
	// Configure Raft
	// -------------------------------------------------------
	raftCfg := raft.DefaultConfig()
	raftCfg.LocalID = raft.ServerID(*nodeID)
	raftCfg.HeartbeatTimeout = time.Duration(*heartbeatMs) * time.Millisecond
	raftCfg.ElectionTimeout = time.Duration(*electionMs) * time.Millisecond
	raftCfg.LeaderLeaseTimeout = time.Duration(*heartbeatMs/2) * time.Millisecond
	raftCfg.CommitTimeout = 500 * time.Millisecond
	raftCfg.SnapshotInterval = 30 * time.Second
	raftCfg.SnapshotThreshold = 1000

	// -------------------------------------------------------
	// Create TCP transport (how nodes talk to each other)
	// -------------------------------------------------------
	addr, err := net.ResolveTCPAddr("tcp", *raftAddr)
	if err != nil {
		log.Fatalf("Failed to resolve address: %v", err)
	}
	transport, err := raft.NewTCPTransport(*raftAddr, addr, 3, 10*time.Second, os.Stderr)
	if err != nil {
		log.Fatalf("Failed to create transport: %v", err)
	}

	// -------------------------------------------------------
	// Create BoltDB store (logs + stable state on disk)
	// -------------------------------------------------------
	boltDB, err := raftboltdb.NewBoltStore(filepath.Join(*dataDir, "raft.db"))
	if err != nil {
		log.Fatalf("Failed to create bolt store: %v", err)
	}

	// -------------------------------------------------------
	// Create snapshot store (for log compaction)
	// -------------------------------------------------------
	snapshots, err := raft.NewFileSnapshotStore(*dataDir, 2, os.Stderr)
	if err != nil {
		log.Fatalf("Failed to create snapshot store: %v", err)
	}

	// -------------------------------------------------------
	// Create Raft instance
	// -------------------------------------------------------
	raftNode, err := raft.NewRaft(raftCfg, fsm, boltDB, boltDB, snapshots, transport)
	if err != nil {
		log.Fatalf("Failed to create raft: %v", err)
	}

	// -------------------------------------------------------
	// Bootstrap if first node
	// -------------------------------------------------------
	if *bootstrap {
		log.Printf("Bootstrapping cluster with node %s", *nodeID)
		config := raft.Configuration{
			Servers: []raft.Server{{
				ID:      raft.ServerID(*nodeID),
				Address: raft.ServerAddress(*raftAddr),
			}},
		}
		f := raftNode.BootstrapCluster(config)
		if err := f.Error(); err != nil {
			log.Printf("Bootstrap note: %v (may already be bootstrapped)", err)
		}
	}

	// -------------------------------------------------------
	// Join existing cluster if join address provided
	// -------------------------------------------------------
	joinAddress := strings.TrimSpace(*joinAddr)
	if joinAddress != "" {
		go func() {
			// Retry joining — leader might not be ready yet
			for i := 0; i < 10; i++ {
				time.Sleep(2 * time.Second)
				log.Printf("Attempting to join via %s (attempt %d)", joinAddress, i+1)
				if err := joinCluster(joinAddress, *nodeID, *raftAddr); err != nil {
					log.Printf("Join attempt %d: %v", i+1, err)
					continue
				}
				log.Printf("Successfully joined cluster")
				return
			}
			log.Printf("Warning: could not join cluster after 10 attempts")
		}()
	}

	// -------------------------------------------------------
	// Start Gin HTTP server
	// -------------------------------------------------------
	router := SetupRouter(raftNode, fsm)
	log.Printf("HTTP server listening on %s", *httpAddr)
	if err := router.Run(*httpAddr); err != nil {
		log.Fatalf("HTTP server failed: %v", err)
	}
}

// joinCluster sends a POST to the leader's /join endpoint
func joinCluster(leaderHTTP, nodeID, raftAddr string) error {
	body, _ := json.Marshal(map[string]string{
		"node_id":   nodeID,
		"raft_addr": raftAddr,
	})
	url := fmt.Sprintf("http://%s/join", leaderHTTP)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("join returned status %d", resp.StatusCode)
	}
	return nil
}

// Helper functions to read env vars with fallbacks
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvBool(key string) bool {
	v := os.Getenv(key)
	return v == "true" || v == "1"
}

func getEnvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n := 0
	for _, c := range v {
		if c >= '0' && c <= '9' {
			n = n*10 + int(c-'0')
		}
	}
	if n == 0 {
		return fallback
	}
	return n
}
