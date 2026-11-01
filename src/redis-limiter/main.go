package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

// tokenBucketScript is an atomic Lua script that implements a continuous
// token bucket — identical semantics to the Raft limiter's refill logic
// but executed atomically inside Redis (no distributed lock needed).
//
// Args: KEYS[1]=bucket key, ARGV[1]=capacity, ARGV[2]=fill_rate_per_sec, ARGV[3]=now_unix_seconds (float)
var tokenBucketScript = redis.NewScript(`
	local key       = KEYS[1]
	local capacity  = tonumber(ARGV[1])
	local fill_rate = tonumber(ARGV[2])
	local now       = tonumber(ARGV[3])

	local bucket      = redis.call("HMGET", key, "tokens", "last_refill")
	local tokens      = tonumber(bucket[1])
	local last_refill = tonumber(bucket[2])

	if tokens == nil then
		tokens      = capacity
		last_refill = now
	end

	local elapsed = now - last_refill
	tokens = math.min(capacity, tokens + elapsed * fill_rate)

	if tokens < 1 then
		redis.call("HMSET", key, "tokens", tostring(tokens), "last_refill", tostring(now))
		redis.call("EXPIRE", key, 3600)
		return {0, tostring(tokens)}
	end

	tokens = tokens - 1
	redis.call("HMSET", key, "tokens", tostring(tokens), "last_refill", tostring(now))
	redis.call("EXPIRE", key, 3600)
	return {1, tostring(tokens)}
`)

type Limiter struct {
	client   *redis.Client
	capacity float64
	fillRate float64
}

func NewLimiter(addr string, capacity, fillRate float64) *Limiter {
	return &Limiter{
		client:   redis.NewClient(&redis.Options{Addr: addr}),
		capacity: capacity,
		fillRate: fillRate,
	}
}

func (l *Limiter) Allow(user string) (allowed bool, remaining float64, err error) {
	ctx := context.Background()
	now := float64(time.Now().UnixNano()) / 1e9

	result, err := tokenBucketScript.Run(ctx, l.client,
		[]string{"ratelimit:" + user},
		l.capacity,
		l.fillRate,
		now,
	).Slice()
	if err != nil {
		return false, 0, err
	}

	allowed = result[0].(int64) == 1
	remaining, _ = strconv.ParseFloat(fmt.Sprintf("%v", result[1]), 64)
	return allowed, remaining, nil
}

func main() {
	addr := getEnv("REDIS_ADDR", "localhost:6379")
	capacity := parseFloat("CAPACITY", 100)
	fillRate := parseFloat("FILL_RATE", 1)
	httpAddr := getEnv("HTTP_ADDR", "0.0.0.0:8000")

	limiter := NewLimiter(addr, capacity, fillRate)

	// GET /check?user=<id>
	// Unified API — same shape as the Raft limiter for fair benchmarking.
	http.HandleFunc("/check", func(w http.ResponseWriter, r *http.Request) {
		user := r.URL.Query().Get("user")
		if user == "" {
			http.Error(w, `{"error":"user parameter is required"}`, http.StatusBadRequest)
			return
		}

		allowed, remaining, err := limiter.Allow(user)
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		if allowed {
			w.WriteHeader(http.StatusOK)
		} else {
			w.WriteHeader(http.StatusTooManyRequests)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"user":      user,
			"allowed":   allowed,
			"remaining": fmt.Sprintf("%.2f", remaining),
		})
	})

	// GET /health — for ALB health checks
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	// GET /status — mirrors Raft's /status for operational parity
	http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"node_state":  "standalone",
			"backend":     "redis",
			"capacity":    capacity,
			"fill_rate":   fillRate,
			"redis_addr":  addr,
		})
	})

	log.Printf("redis-limiter starting on %s (capacity=%.0f fill_rate=%.2f/s)", httpAddr, capacity, fillRate)
	log.Fatal(http.ListenAndServe(httpAddr, nil))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseFloat(key string, fallback float64) float64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return fallback
	}
	return f
}
