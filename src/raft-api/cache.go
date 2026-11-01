package main

import (
	"sync"
	"time"
)

// CacheEntry holds a cached rate-limit decision for one user.
// We cache both Allowed status and Remaining tokens so repeat requests
// from the same user don't need to hit Raft.
type CacheEntry struct {
	Allowed   bool
	Remaining float64
	ExpiresAt time.Time
}

// Cache is an in-memory per-task cache of rate-limit decisions.
// Each ECS task has its own independent cache — no cross-task coordination.
// This gives us per-task approximate rate limiting (industry standard).
type Cache struct {
	mu      sync.RWMutex
	entries map[string]CacheEntry
	ttl     time.Duration

	// Metrics for observability
	hits   int64
	misses int64
}

// NewCache builds a cache with the given TTL and starts a background
// goroutine to evict expired entries every second.
func NewCache(ttl time.Duration) *Cache {
	c := &Cache{
		entries: make(map[string]CacheEntry),
		ttl:     ttl,
	}
	go c.evictLoop()
	return c
}

// Get returns the cached entry for a user if it's still fresh.
// If the entry is expired or missing, returns (zero value, false).
func (c *Cache) Get(user string) (CacheEntry, bool) {
	c.mu.RLock()
	entry, ok := c.entries[user]
	c.mu.RUnlock()

	if !ok {
		c.mu.Lock()
		c.misses++
		c.mu.Unlock()
		return CacheEntry{}, false
	}

	if time.Now().After(entry.ExpiresAt) {
		c.mu.Lock()
		c.misses++
		c.mu.Unlock()
		return CacheEntry{}, false
	}

	c.mu.Lock()
	c.hits++
	c.mu.Unlock()
	return entry, true
}

// Set stores a rate-limit decision for a user with the configured TTL.
func (c *Cache) Set(user string, allowed bool, remaining float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[user] = CacheEntry{
		Allowed:   allowed,
		Remaining: remaining,
		ExpiresAt: time.Now().Add(c.ttl),
	}
}

// Decrement updates a cached entry to reflect a locally-served request.
// Called when we serve a request from cache without touching Raft —
// the cached token count goes down by 1 so the next cache hit reflects it.
// If the entry is missing or expired, this is a no-op (a fresh forward will happen).
func (c *Cache) Decrement(user string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	entry, ok := c.entries[user]
	if !ok || time.Now().After(entry.ExpiresAt) {
		return
	}

	if entry.Remaining >= 1 {
		entry.Remaining--
		entry.Allowed = entry.Remaining >= 1
	} else {
		entry.Allowed = false
	}
	c.entries[user] = entry
}

// Stats returns cache metrics for /status observability.
func (c *Cache) Stats() map[string]interface{} {
	c.mu.RLock()
	defer c.mu.RUnlock()

	total := c.hits + c.misses
	var hitRate float64
	if total > 0 {
		hitRate = float64(c.hits) / float64(total)
	}

	return map[string]interface{}{
		"entries":  len(c.entries),
		"hits":     c.hits,
		"misses":   c.misses,
		"hit_rate": hitRate,
		"ttl_ms":   c.ttl.Milliseconds(),
	}
}

// evictLoop runs in the background and removes expired entries every second.
// Without this, the map would grow unboundedly for users who hit the API
// once and never again.
func (c *Cache) evictLoop() {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		c.evictExpired()
	}
}

func (c *Cache) evictExpired() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	for user, entry := range c.entries {
		if now.After(entry.ExpiresAt) {
			delete(c.entries, user)
		}
	}
}