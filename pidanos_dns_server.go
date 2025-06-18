// src/dns/main.go
package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
)

type PidanosServer struct {
	blocklist     map[string]bool
	cache         map[string]*dns.Msg
	cacheMutex    sync.RWMutex
	upstreamDNS   string
	blockedCount  uint64
	totalQueries  uint64
	mutex         sync.RWMutex
}

func NewPidanosServer() *PidanosServer {
	return &PidanosServer{
		blocklist:   make(map[string]bool),
		cache:       make(map[string]*dns.Msg),
		upstreamDNS: "8.8.8.8:53", // Google DNS as default
	}
}

func (s *PidanosServer) LoadBlocklist(filename string) error {
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	count := 0
	
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		
		// Handle different formats (hosts file, domain list, etc.)
		parts := strings.Fields(line)
		var domain string
		
		if len(parts) >= 2 && (parts[0] == "0.0.0.0" || parts[0] == "127.0.0.1") {
			domain = parts[1]
		} else if len(parts) == 1 {
			domain = parts[0]
		} else {
			continue
		}
		
		domain = strings.ToLower(strings.TrimSpace(domain))
		if domain != "" && domain != "localhost" {
			s.blocklist[domain] = true
			count++
		}
	}
	
	log.Printf("📋 Loaded %d domains to blocklist", count)
	return scanner.Err()
}

func (s *PidanosServer) IsBlocked(domain string) bool {
	domain = strings.ToLower(domain)
	
	// Check exact match
	if s.blocklist[domain] {
		return true
	}
	
	// Check subdomains
	parts := strings.Split(domain, ".")
	for i := 1; i < len(parts); i++ {
		parent := strings.Join(parts[i:], ".")
		if s.blocklist[parent] {
			return true
		}
	}
	
	return false
}

func (s *PidanosServer) handleDNSRequest(w dns.ResponseWriter, r *dns.Msg) {
	m := new(dns.Msg)
	m.SetReply(r)
	m.Compress = false
	
	s.mutex.Lock()
	s.totalQueries++
	s.mutex.Unlock()
	
	for _, q := range r.Question {
		domain := strings.TrimSuffix(q.Name, ".")
		
		log.Printf("🔍 Query: %s (%s)", domain, dns.TypeToString[q.Qtype])
		
		// Check if domain is blocked
		if s.IsBlocked(domain) {
			log.Printf("🚫 Blocked: %s", domain)
			
			s.mutex.Lock()
			s.blockedCount++
			s.mutex.Unlock()
			
			// Return NXDOMAIN for blocked domains
			m.SetRcode(r, dns.RcodeNameError)
			w.WriteMsg(m)
			return
		}
		
		// Check cache first
		cacheKey := fmt.Sprintf("%s:%d", domain, q.Qtype)
		s.cacheMutex.RLock()
		if cachedMsg, exists := s.cache[cacheKey]; exists {
			s.cacheMutex.RUnlock()
			log.Printf("💾 Cache hit: %s", domain)
			
			// Update message ID
			cachedMsg.Id = r.Id
			w.WriteMsg(cachedMsg)
			return
		}
		s.cacheMutex.RUnlock()
		
		// Forward to upstream DNS
		resp := s.forwardQuery(r)
		if resp != nil {
			// Cache the response (for 5 minutes)
			s.cacheMutex.Lock()
			s.cache[cacheKey] = resp.Copy()
			s.cacheMutex.Unlock()
			
			// Clean old cache entries periodically
			go s.cleanCache()
			
			log.Printf("✅ Resolved: %s", domain)
			w.WriteMsg(resp)
			return
		}
	}
	
	// If we get here, something went wrong
	m.SetRcode(r, dns.RcodeServerFailure)
	w.WriteMsg(m)
}

func (s *PidanosServer) forwardQuery(r *dns.Msg) *dns.Msg {
	c := new(dns.Client)
	c.Timeout = 5 * time.Second
	
	resp, _, err := c.Exchange(r, s.upstreamDNS)
	if err != nil {
		log.Printf("❌ DNS forward error: %v", err)
		return nil
	}
	
	return resp
}

func (s *PidanosServer) cleanCache() {
	// Simple cache cleanup - remove entries older than 5 minutes
	// In production, you'd want a more sophisticated LRU cache
	time.Sleep(30 * time.Second)
	
	s.cacheMutex.Lock()
	defer s.cacheMutex.Unlock()
	
	if len(s.cache) > 1000 { // Keep cache size reasonable
		// Clear half the cache (simple approach)
		count := 0
		for k := range s.cache {
			delete(s.cache, k)
			count++
			if count > 500 {
				break
			}
		}
		log.Printf("🧹 Cleaned cache, removed %d entries", count)
	}
}

func (s *PidanosServer) GetStats() (uint64, uint64, float64) {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	
	var blockedPercentage float64
	if s.totalQueries > 0 {
		blockedPercentage = float64(s.blockedCount) / float64(s.totalQueries) * 100
	}
	
	return s.totalQueries, s.blockedCount, blockedPercentage
}

func (s *PidanosServer) Start(port string) {
	server := &dns.Server{
		Addr: ":" + port,
		Net:  "udp",
	}
	
	dns.HandleFunc(".", s.handleDNSRequest)
	
	log.Printf("🚀 Pidanos DNS Server starting on port %s", port)
	log.Printf("🌍 Upstream DNS: %s", s.upstreamDNS)
	
	err := server.ListenAndServe()
	if err != nil {
		log.Fatalf("💥 Failed to start server: %v", err)
	}
}

func main() {
	server := NewPidanosServer()
	
	// Load default blocklist
	if err := server.LoadBlocklist("../../config/lists/ads.txt"); err != nil {
		log.Printf("⚠️  Warning: Could not load blocklist: %v", err)
		log.Printf("📝 Creating sample blocklist...")
		
		// Create a sample blocklist for testing
		sampleDomains := []string{
			"doubleclick.net",
			"googleadservices.com",
			"googlesyndication.com",
			"googletagmanager.com",
			"facebook.com",
			"analytics.google.com",
		}
		
		for _, domain := range sampleDomains {
			server.blocklist[domain] = true
		}
		log.Printf("📋 Loaded %d sample domains", len(sampleDomains))
	}
	
	// Start stats printer
	go func() {
		for {
			time.Sleep(30 * time.Second)
			total, blocked, percentage := server.GetStats()
			log.Printf("📊 Stats: %d queries, %d blocked (%.1f%%)", total, blocked, percentage)
		}
	}()
	
	// Start DNS server
	server.Start("53")
}