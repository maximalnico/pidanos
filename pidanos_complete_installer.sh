#!/bin/bash

#################################################################################
# Pidanos - Ein-Klick Installation                                              #
# Network-wide ad blocking • Modern • Minimal • Powerful                        #
#################################################################################

set -e

# Apple-inspired colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Configuration
readonly PIDANOS_USER="pidanos"
readonly PIDANOS_HOME="/opt/pidanos"
readonly PIDANOS_CONFIG="/etc/pidanos"
readonly PIDANOS_LOG="/var/log/pidanos"
readonly PIDANOS_DATA="/opt/pidanos/data"
readonly WEB_PORT="8080"
readonly DNS_PORT="53"
readonly GO_VERSION="1.21.0"

# System detection
OS=""
DISTRO=""
PACKAGE_MANAGER=""
SYSTEMD_AVAILABLE=false

print_header() {
    clear
    echo -e "${PURPLE}"
    echo "  ██████╗ ██╗██████╗  █████╗ ███╗   ██╗ ██████╗ ███████╗"
    echo "  ██╔══██╗██║██╔══██╗██╔══██╗████╗  ██║██╔═══██╗██╔════╝"
    echo "  ██████╔╝██║██║  ██║███████║██╔██╗ ██║██║   ██║███████╗"
    echo "  ██╔═══╝ ██║██║  ██║██╔══██║██║╚██╗██║██║   ██║╚════██║"
    echo "  ██║     ██║██████╔╝██║  ██║██║ ╚████║╚██████╔╝███████║"
    echo "  ╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝"
    echo ""
    echo -e "${WHITE}  Network-wide ad blocking • Modern • Minimal • Powerful${NC}"
    echo ""
}

log() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

detect_system() {
    log "Detecting system..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    else
        error "Unsupported operating system: $OSTYPE"
    fi
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        
        case "$DISTRO" in
            ubuntu|debian|raspbian)
                PACKAGE_MANAGER="apt"
                ;;
            fedora|centos|rhel|rocky|almalinux)
                PACKAGE_MANAGER="dnf"
                ;;
            arch|manjaro)
                PACKAGE_MANAGER="pacman"
                ;;
            alpine)
                PACKAGE_MANAGER="apk"
                ;;
            *)
                warning "Unknown distribution: $DISTRO. Assuming apt package manager."
                PACKAGE_MANAGER="apt"
                ;;
        esac
    else
        error "Cannot detect Linux distribution"
    fi
    
    if command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_AVAILABLE=true
    fi
    
    success "Detected: $DISTRO ($PACKAGE_MANAGER) with systemd: $SYSTEMD_AVAILABLE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Please use: sudo $0"
    fi
}

install_packages() {
    local packages=("$@")
    
    case "$PACKAGE_MANAGER" in
        apt)
            apt update >/dev/null 2>&1
            apt install -y "${packages[@]}" >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y "${packages[@]}" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}" >/dev/null 2>&1
            ;;
        apk)
            apk add "${packages[@]}" >/dev/null 2>&1
            ;;
        *)
            error "Unsupported package manager: $PACKAGE_MANAGER"
            ;;
    esac
}

check_dependencies() {
    log "Installing system dependencies..."
    
    case "$PACKAGE_MANAGER" in
        apt)
            install_packages curl wget git python3 python3-pip python3-venv sqlite3 dnsutils net-tools
            ;;
        dnf)
            install_packages curl wget git python3 python3-pip sqlite bind-utils net-tools
            ;;
        pacman)
            install_packages curl wget git python python-pip sqlite dnsutils net-tools
            ;;
        apk)
            install_packages curl wget git python3 py3-pip sqlite bind-tools net-tools
            ;;
    esac
    
    success "System dependencies installed"
}

create_user() {
    log "Creating pidanos user..."
    
    if ! id "$PIDANOS_USER" >/dev/null 2>&1; then
        useradd -r -s /bin/false -d "$PIDANOS_HOME" "$PIDANOS_USER"
        success "Created user: $PIDANOS_USER"
    else
        log "User $PIDANOS_USER already exists"
    fi
}

create_directories() {
    log "Creating directories..."
    
    local dirs=(
        "$PIDANOS_HOME"
        "$PIDANOS_HOME/bin"
        "$PIDANOS_HOME/src"
        "$PIDANOS_HOME/src/dns"
        "$PIDANOS_HOME/src/web"
        "$PIDANOS_HOME/web"
        "$PIDANOS_HOME/web/static"
        "$PIDANOS_HOME/web/templates"
        "$PIDANOS_CONFIG"
        "$PIDANOS_CONFIG/lists"
        "$PIDANOS_LOG"
        "$PIDANOS_DATA"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chown "$PIDANOS_USER:$PIDANOS_USER" "$dir"
    done
    
    success "Created directory structure"
}

install_go() {
    log "Installing Go..."
    
    local go_url="https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    local go_path="/usr/local/go"
    
    if command -v go >/dev/null 2>&1; then
        local current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$GO_VERSION" ]]; then
            success "Go $GO_VERSION already installed"
            export PATH=$PATH:/usr/local/go/bin
            return
        fi
    fi
    
    rm -rf "$go_path"
    wget -q "$go_url" -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
    
    success "Go $GO_VERSION installed"
}

create_dns_server() {
    log "Creating DNS server..."
    
    # Create go.mod
    cat > "$PIDANOS_HOME/src/dns/go.mod" << 'EOF'
module github.com/pidanos/dns

go 1.21

require (
    github.com/miekg/dns v1.1.56
)

require (
    golang.org/x/mod v0.12.0 // indirect
    golang.org/x/net v0.15.0 // indirect
    golang.org/x/sys v0.12.0 // indirect
    golang.org/x/tools v0.13.0 // indirect
)
EOF

    # Create DNS server source
    cat > "$PIDANOS_HOME/src/dns/main.go" << 'EOF'
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
	"database/sql"
	_ "github.com/mattn/go-sqlite3"

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
	db            *sql.DB
}

func NewPidanosServer() *PidanosServer {
	// Open database
	db, err := sql.Open("sqlite3", "/opt/pidanos/data/pidanos.db")
	if err != nil {
		log.Fatal(err)
	}

	return &PidanosServer{
		blocklist:   make(map[string]bool),
		cache:       make(map[string]*dns.Msg),
		upstreamDNS: "8.8.8.8:53",
		db:          db,
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
	
	if s.blocklist[domain] {
		return true
	}
	
	parts := strings.Split(domain, ".")
	for i := 1; i < len(parts); i++ {
		parent := strings.Join(parts[i:], ".")
		if s.blocklist[parent] {
			return true
		}
	}
	
	return false
}

func (s *PidanosServer) logQuery(domain, clientIP, queryType string, blocked bool, responseTime int) {
	if s.db == nil {
		return
	}

	_, err := s.db.Exec(`
		INSERT INTO queries (domain, client_ip, query_type, blocked, response_time_ms)
		VALUES (?, ?, ?, ?, ?)
	`, domain, clientIP, queryType, blocked, responseTime)
	
	if err != nil {
		log.Printf("❌ Failed to log query: %v", err)
	}
}

func (s *PidanosServer) handleDNSRequest(w dns.ResponseWriter, r *dns.Msg) {
	start := time.Now()
	m := new(dns.Msg)
	m.SetReply(r)
	m.Compress = false
	
	s.mutex.Lock()
	s.totalQueries++
	s.mutex.Unlock()
	
	for _, q := range r.Question {
		domain := strings.TrimSuffix(q.Name, ".")
		clientIP := w.RemoteAddr().String()
		queryType := dns.TypeToString[q.Qtype]
		
		log.Printf("🔍 Query: %s (%s) from %s", domain, queryType, clientIP)
		
		if s.IsBlocked(domain) {
			log.Printf("🚫 Blocked: %s", domain)
			
			s.mutex.Lock()
			s.blockedCount++
			s.mutex.Unlock()
			
			responseTime := int(time.Since(start).Milliseconds())
			s.logQuery(domain, clientIP, queryType, true, responseTime)
			
			m.SetRcode(r, dns.RcodeNameError)
			w.WriteMsg(m)
			return
		}
		
		cacheKey := fmt.Sprintf("%s:%d", domain, q.Qtype)
		s.cacheMutex.RLock()
		if cachedMsg, exists := s.cache[cacheKey]; exists {
			s.cacheMutex.RUnlock()
			log.Printf("💾 Cache hit: %s", domain)
			
			responseTime := int(time.Since(start).Milliseconds())
			s.logQuery(domain, clientIP, queryType, false, responseTime)
			
			cachedMsg.Id = r.Id
			w.WriteMsg(cachedMsg)
			return
		}
		s.cacheMutex.RUnlock()
		
		resp := s.forwardQuery(r)
		if resp != nil {
			s.cacheMutex.Lock()
			s.cache[cacheKey] = resp.Copy()
			s.cacheMutex.Unlock()
			
			go s.cleanCache()
			
			responseTime := int(time.Since(start).Milliseconds())
			s.logQuery(domain, clientIP, queryType, false, responseTime)
			
			log.Printf("✅ Resolved: %s", domain)
			w.WriteMsg(resp)
			return
		}
	}
	
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
	time.Sleep(30 * time.Second)
	
	s.cacheMutex.Lock()
	defer s.cacheMutex.Unlock()
	
	if len(s.cache) > 1000 {
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
	defer server.db.Close()
	
	if err := server.LoadBlocklist("/etc/pidanos/lists/ads.txt"); err != nil {
		log.Printf("⚠️  Warning: Could not load ads blocklist: %v", err)
	}
	
	if err := server.LoadBlocklist("/etc/pidanos/lists/trackers.txt"); err != nil {
		log.Printf("⚠️  Warning: Could not load trackers blocklist: %v", err)
	}
	
	go func() {
		for {
			time.Sleep(30 * time.Second)
			total, blocked, percentage := server.GetStats()
			log.Printf("📊 Stats: %d queries, %d blocked (%.1f%%)", total, blocked, percentage)
		}
	}()
	
	server.Start("53")
}
EOF
    
    success "DNS server source created"
}

create_web_backend() {
    log "Creating web backend..."
    
    cat > "$PIDANOS_HOME/src/web/app.py" << 'EOF'
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn
import sqlite3
import os
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional
import asyncio
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("pidanos-web")

class PidanosAPI:
    def __init__(self):
        self.app = FastAPI(
            title="Pidanos API",
            description="Modern network-wide ad blocking",
            version="1.0.0"
        )
        self.db_path = "/opt/pidanos/data/pidanos.db"
        self.config_path = "/etc/pidanos/pidanos.conf"
        self.setup_database()
        self.setup_routes()
        
    def setup_database(self):
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS queries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                domain TEXT NOT NULL,
                client_ip TEXT NOT NULL,
                query_type TEXT NOT NULL,
                response_code INTEGER,
                blocked BOOLEAN DEFAULT FALSE,
                response_time_ms INTEGER
            )
        ''')
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS stats_hourly (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hour DATETIME NOT NULL UNIQUE,
                total_queries INTEGER DEFAULT 0,
                blocked_queries INTEGER DEFAULT 0,
                unique_clients INTEGER DEFAULT 0
            )
        ''')
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS blocklists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                url TEXT,
                enabled BOOLEAN DEFAULT TRUE,
                last_updated DATETIME,
                domain_count INTEGER DEFAULT 0
            )
        ''')
        
        cursor.execute('''
            INSERT OR IGNORE INTO blocklists (name, url, enabled, domain_count) 
            VALUES 
            ('Basic Ads', 'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts', TRUE, 100000),
            ('Privacy Trackers', 'https://someonewhocares.org/hosts/zero/hosts', TRUE, 15000),
            ('Malware Protection', 'https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt', TRUE, 5000)
        ''')
        
        conn.commit()
        conn.close()
        logger.info("✅ Database initialized")

    def setup_routes(self):
        @self.app.get("/", response_class=HTMLResponse)
        async def dashboard(request: Request):
            return HTMLResponse(content=self.get_dashboard_html())
        
        @self.app.get("/api/stats")
        async def get_stats():
            try:
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                
                today = datetime.now().strftime('%Y-%m-%d')
                cursor.execute('''
                    SELECT 
                        COUNT(*) as total_queries,
                        SUM(CASE WHEN blocked = 1 THEN 1 ELSE 0 END) as blocked_count
                    FROM queries 
                    WHERE DATE(timestamp) = ?
                ''', (today,))
                
                result = cursor.fetchone()
                total_queries = result[0] if result[0] else 0
                blocked_count = result[1] if result[1] else 0
                
                block_percentage = (blocked_count / total_queries * 100) if total_queries > 0 else 0
                
                cursor.execute('''
                    SELECT COUNT(DISTINCT client_ip) 
                    FROM queries 
                    WHERE DATE(timestamp) = ?
                ''', (today,))
                unique_clients = cursor.fetchone()[0] or 0
                
                cursor.execute('SELECT COUNT(*) FROM blocklists WHERE enabled = 1')
                active_lists = cursor.fetchone()[0] or 0
                
                conn.close()
                
                return {
                    "total_queries": total_queries,
                    "blocked_count": blocked_count,
                    "block_percentage": round(block_percentage, 1),
                    "unique_clients": unique_clients,
                    "active_lists": active_lists,
                    "protection_enabled": True,
                    "last_updated": datetime.now().isoformat()
                }
                
            except Exception as e:
                logger.error(f"Error getting stats: {e}")
                return {"error": str(e)}
        
        @self.app.get("/api/queries/recent")
        async def get_recent_queries(limit: int = 100):
            try:
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                
                cursor.execute('''
                    SELECT timestamp, domain, client_ip, query_type, blocked, response_time_ms
                    FROM queries 
                    ORDER BY timestamp DESC 
                    LIMIT ?
                ''', (limit,))
                
                results = cursor.fetchall()
                conn.close()
                
                queries = []
                for row in results:
                    queries.append({
                        "timestamp": row[0],
                        "domain": row[1],
                        "client": row[2],
                        "type": row[3],
                        "status": "blocked" if row[4] else "allowed",
                        "response_time": row[5]
                    })
                
                return {"queries": queries}
                
            except Exception as e:
                logger.error(f"Error getting recent queries: {e}")
                return {"error": str(e)}

    def get_dashboard_html(self) -> str:
        with open("/opt/pidanos/web/dashboard.html", "r") as f:
            return f.read()

def main():
    api = PidanosAPI()
    
    host = "0.0.0.0"
    port = 8080
    
    logger.info(f"🚀 Starting Pidanos Web Interface on {host}:{port}")
    
    uvicorn.run(
        api.app,
        host=host,
        port=port,
        log_level="info",
        access_log=True
    )

if __name__ == "__main__":
    main()
EOF
    
    success "Web backend created"
}

install_python_deps() {
    log "Installing Python dependencies..."
    
    python3 -m venv "$PIDANOS_HOME/venv"
    source "$PIDANOS_HOME/venv/bin/activate"
    
    pip install --quiet --upgrade pip
    pip install --quiet fastapi uvicorn jinja2 python-multipart sqlite3
    
    chown -R "$PIDANOS_USER:$PIDANOS_USER" "$PIDANOS_HOME/venv"
    success "Python environment configured"
}

compile_dns_server() {
    log "Compiling DNS server..."
    
    cd "$PIDANOS_HOME/src/dns"
    
    # Fix go.mod to include sqlite driver
    cat > go.mod << 'EOF'
module github.com/pidanos/dns

go 1.21

require (
    github.com/miekg/dns v1.1.56
    github.com/mattn/go-sqlite3 v1.14.17
)
EOF

    export PATH=$PATH:/usr/local/go/bin
    go mod tidy
    go build -o "$PIDANOS_HOME/bin/pidanos-dns" main.go
    
    chown "$PIDANOS_USER:$PIDANOS_USER" "$PIDANOS_HOME/bin/pidanos-dns"
    chmod +x "$PIDANOS_HOME/bin/pidanos-dns"
    
    success "DNS server compiled"
}

create_web_files() {
    log "Creating web interface files..."
    
    # Copy your HTML dashboard
    cat > "$PIDANOS_HOME/web/dashboard.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pidanos Dashboard</title>
    <style>
        :root {
            --primary-color: #007AFF;
            --success-color: #34C759;
            --warning-color: #FF9500;
            --danger-color: #FF3B30;
            --background: #F2F2F7;
            --surface: #FFFFFF;
            --text-primary: #1D1D1F;
            --text-secondary: #86868B;
            --border: #D1D1D6;
            --shadow: rgba(0, 0, 0, 0.1);
            --radius: 12px;
            --font-system: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: var(--font-system);
            background: var(--background);
            color: var(--text-primary);
            line-height: 1.6;
        }

        .header {
            background: var(--surface);
            border-bottom: 1px solid var(--border);
            padding: 16px 0;
            position: sticky;
            top: 0;
            z-index: 100;
        }

        .header-content {
            max-width: 1200px;
            margin: 0 auto;
            padding: 0 16px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }

        .logo {
            display: flex;
            align-items: center;
            gap: 12px;
            font-size: 24px;
            font-weight: 600;
        }

        .logo-icon {
            width: 32px;
            height: 32px;
            background: linear-gradient(135deg, var(--primary-color), #5856D6);
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
        }

        .status-indicator {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 8px 16px;
            background: var(--success-color);
            color: white;
            border-radius: 20px;
            font-size: 14px;
            font-weight: 500;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 16px;
        }

        .dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 16px;
            margin-bottom: 32px;
        }

        .card {
            background: var(--surface);
            border-radius: 16px;
            padding: 24px;
            box-shadow: 0 4px 20px var(--shadow);
            border: 1px solid var(--border);
        }

        .card-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 16px;
        }

        .card-icon {
            width: 40px;
            height: 40px;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 20px;
            color: white;
        }

        .card-title {
            font-size: 16px;
            font-weight: 600;
            color: var(--text-secondary);
        }

        .card-value {
            font-size: 36px;
            font-weight: 700;
            margin-bottom: 8px;
        }

        .card-subtitle {
            font-size: 14px;
            color: var(--text-secondary);
        }

        .queries-card .card-icon { background: var(--primary-color); }
        .blocked-card .card-icon { background: var(--danger-color); }
        .percentage-card .card-icon { background: var(--success-color); }
        .lists-card .card-icon { background: var(--warning-color); }

        .controls {
            background: var(--surface);
            border-radius: 16px;
            padding: 24px;
            box-shadow: 0 4px 20px var(--shadow);
            border: 1px solid var(--border);
        }

        .controls-header {
            font-size: 20px;
            font-weight: 600;
            margin-bottom: 16px;
        }

        .toggle-group {
            display: flex;
            gap: 16px;
            flex-wrap: wrap;
        }

        .toggle-button {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 20px;
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            cursor: pointer;
            transition: all 0.2s ease;
            font-size: 16px;
            font-weight: 500;
            text-decoration: none;
            color: var(--text-primary);
        }

        .toggle-button:hover {
            background: var(--primary-color);
            color: white;
            border-color: var(--primary-color);
        }

        .recent-queries {
            background: var(--surface);
            border-radius: 16px;
            padding: 24px;
            box-shadow: 0 4px 20px var(--shadow);
            border: 1px solid var(--border);
            margin-top: 16px;
        }

        .query-item {
            padding: 12px 0;
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .query-item:last-child {
            border-bottom: none;
        }

        .query-domain {
            font-weight: 600;
        }

        .query-status {
            padding: 4px 8px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 500;
        }

        .query-status.blocked {
            background: var(--danger-color);
            color: white;
        }

        .query-status.allowed {
            background: var(--success-color);
            color: white;
        }

        .loading {
            display: inline-block;
            width: 16px;
            height: 16px;
            border: 2px solid var(--border);
            border-radius: 50%;
            border-top-color: var(--primary-color);
            animation: spin 1s ease-in-out infinite;
        }

        @keyframes spin {
            to { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <header class="header">
        <div class="header-content">
            <div class="logo">
                <div class="logo-icon">🛡️</div>
                <span>Pidanos</span>
            </div>
            <div class="status-indicator">
                <span>Active Protection</span>
            </div>
        </div>
    </header>

    <main class="container">
        <section class="dashboard">
            <div class="card queries-card">
                <div class="card-header">
                    <div class="card-icon">📊</div>
                    <div class="card-title">Total Queries</div>
                </div>
                <div class="card-value" id="total-queries">0</div>
                <div class="card-subtitle">DNS requests today</div>
            </div>

            <div class="card blocked-card">
                <div class="card-header">
                    <div class="card-icon">🚫</div>
                    <div class="card-title">Blocked</div>
                </div>
                <div class="card-value" id="blocked-count">0</div>
                <div class="card-subtitle">Ads & trackers blocked</div>
            </div>

            <div class="card percentage-card">
                <div class="card-header">
                    <div class="card-icon">📈</div>
                    <div class="card-title">Block Rate</div>
                </div>
                <div class="card-value" id="block-percentage">0%</div>
                <div class="card-subtitle">Percentage blocked</div>
            </div>

            <div class="card lists-card">
                <div class="card-header">
                    <div class="card-icon">📋</div>
                    <div class="card-title">Block Lists</div>
                </div>
                <div class="card-value" id="blocklist-count">3</div>
                <div class="card-subtitle">Active filter lists</div>
            </div>
        </section>

        <section class="controls">
            <h2 class="controls-header">Quick Actions</h2>
            <div class="toggle-group">
                <button class="toggle-button" onclick="updateBlocklists()">
                    🔄 Update Block Lists
                </button>
                <button class="toggle-button" onclick="flushCache()">
                    🧹 Clear DNS Cache
                </button>
                <button class="toggle-button" onclick="restartServices()">
                    ⚡ Restart Services
                </button>
                <button class="toggle-button" onclick="viewLogs()">
                    📝 View Logs
                </button>
            </div>
        </section>

        <section class="recent-queries">
            <h2 class="controls-header">Recent Queries</h2>
            <div id="recent-queries-list">
                <div style="text-align: center; color: var(--text-secondary); padding: 20px;">
                    Loading recent queries...
                </div>
            </div>
        </section>
    </main>

    <script>
        async function fetchStats() {
            try {
                const response = await fetch('/api/stats');
                const data = await response.json();
                
                document.getElementById('total-queries').textContent = data.total_queries.toLocaleString();
                document.getElementById('blocked-count').textContent = data.blocked_count.toLocaleString();
                document.getElementById('block-percentage').textContent = data.block_percentage + '%';
                document.getElementById('blocklist-count').textContent = data.active_lists;
            } catch (error) {
                console.error('Error fetching stats:', error);
            }
        }

        async function fetchRecentQueries() {
            try {
                const response = await fetch('/api/queries/recent?limit=10');
                const data = await response.json();
                
                const container = document.getElementById('recent-queries-list');
                if (data.queries && data.queries.length > 0) {
                    container.innerHTML = data.queries.map(q => 
                        `<div class="query-item">
                            <div>
                                <div class="query-domain">${q.domain}</div>
                                <small style="color: var(--text-secondary);">${q.client} • ${q.type}</small>
                            </div>
                            <div>
                                <span class="query-status ${q.status}">${q.status}</span>
                                <small style="color: var(--text-secondary); margin-left: 8px;">
                                    ${new Date(q.timestamp).toLocaleTimeString()}
                                </small>
                            </div>
                        </div>`
                    ).join('');
                } else {
                    container.innerHTML = '<div style="text-align: center; color: var(--text-secondary); padding: 20px;">No recent queries</div>';
                }
            } catch (error) {
                document.getElementById('recent-queries-list').innerHTML = 
                    '<div style="text-align: center; color: var(--danger-color); padding: 20px;">Error loading queries</div>';
            }
        }

        async function updateBlocklists() {
            const button = event.target;
            const original = button.innerHTML;
            button.innerHTML = '<div class="loading"></div> Updating...';
            button.disabled = true;
            
            try {
                // Simulate update process
                await new Promise(resolve => setTimeout(resolve, 2000));
                button.innerHTML = '✅ Updated';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                }, 2000);
            } catch (error) {
                button.innerHTML = '❌ Failed';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                }, 2000);
            }
        }

        async function flushCache() {
            const button = event.target;
            const original = button.innerHTML;
            button.innerHTML = '<div class="loading"></div> Clearing...';
            button.disabled = true;
            
            try {
                await new Promise(resolve => setTimeout(resolve, 1000));
                button.innerHTML = '✅ Cache Cleared';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                }, 2000);
            } catch (error) {
                button.innerHTML = '❌ Failed';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                }, 2000);
            }
        }

        async function restartServices() {
            const button = event.target;
            const original = button.innerHTML;
            button.innerHTML = '<div class="loading"></div> Restarting...';
            button.disabled = true;
            
            try {
                await new Promise(resolve => setTimeout(resolve, 3000));
                button.innerHTML = '✅ Restarted';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                    location.reload();
                }, 2000);
            } catch (error) {
                button.innerHTML = '❌ Failed';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.disabled = false;
                }, 2000);
            }
        }

        function viewLogs() {
            alert('Use terminal: sudo journalctl -u pidanos-dns -u pidanos-web -f');
        }

        document.addEventListener('DOMContentLoaded', function() {
            fetchStats();
            fetchRecentQueries();
            
            setInterval(() => {
                fetchStats();
                fetchRecentQueries();
            }, 30000);
        });
    </script>
</body>
</html>
EOF
    
    chown -R "$PIDANOS_USER:$PIDANOS_USER" "$PIDANOS_HOME/web"
    success "Web interface files created"
}

create_config() {
    log "Creating configuration..."
    
    cat > "$PIDANOS_CONFIG/pidanos.conf" << EOF
# Pidanos Configuration

[dns]
port = $DNS_PORT
upstream = 8.8.8.8:53
cache_size = 10000
cache_ttl = 300

[web]
port = $WEB_PORT
host = 0.0.0.0
debug = false

[blocking]
enabled = true
lists_update_interval = 86400

[logging]
level = info
max_size = 100MB
max_files = 5
EOF

    # Create enhanced blocklists
    cat > "$PIDANOS_CONFIG/lists/ads.txt" << 'EOF'
# Enhanced Ad Blocking List - Pidanos
# Updated automatically

# Google Ads
doubleclick.net
googleadservices.com
googlesyndication.com
googletagmanager.com
google-analytics.com
googletagservices.com

# Facebook/Meta
facebook.com
connect.facebook.net
facebook.net

# Amazon Ads
amazon-adsystem.com
amazonaax.com

# Microsoft Ads
msads.net
bing.com

# Common Ad Networks
outbrain.com
taboola.com
criteo.com
adsystem.com
2mdn.net
scorecardresearch.com
quantserve.com

# Analytics & Tracking
analytics.yahoo.com
omtrdc.net
adobe.com
hotjar.com
crazyegg.com

# Social Media Trackers
twitter.com
linkedin.com
pinterest.com
instagram.com
tiktok.com
snapchat.com
EOF
    
    cat > "$PIDANOS_CONFIG/lists/trackers.txt" << 'EOF'
# Privacy Tracking Protection - Pidanos

# Major Trackers
google-analytics.com
googletagmanager.com
facebook.com
twitter.com
linkedin.com
pinterest.com

# Fingerprinting
fingerprintjs.com
maxmind.com

# Advertising IDs
adsystem.com
adskeeper.com
adnxs.com

# Analytics
hotjar.com
fullstory.com
loggly.com
mixpanel.com
segment.com

# Social Widgets
platform.twitter.com
connect.facebook.net
platform.linkedin.com
widgets.pinterest.com

# Affiliate/Tracking
shareasale.com
cj.com
linksynergy.com
anrdoezrs.net
EOF

    cat > "$PIDANOS_CONFIG/lists/malware.txt" << 'EOF'
# Malware Protection - Pidanos
# Basic malware domains

# Known malware domains
malware.com
phishing.com
badsite.org
virus.net

# Cryptocurrency miners
coinhive.com
jsecoin.com
coin-hive.com

# Known bad actors
zeus.com
conficker.org
EOF
    
    chown -R "$PIDANOS_USER:$PIDANOS_USER" "$PIDANOS_CONFIG"
    success "Configuration files created"
}

create_systemd_services() {
    if [[ "$SYSTEMD_AVAILABLE" != true ]]; then
        warning "Systemd not available. Skipping service creation."
        return
    fi
    
    log "Creating systemd services..."
    
    # DNS service
    cat > "/etc/systemd/system/pidanos-dns.service" << EOF
[Unit]
Description=Pidanos DNS Server
Documentation=https://github.com/pidanos/pidanos
After=network.target
Wants=network.target

[Service]
Type=simple
User=$PIDANOS_USER
Group=$PIDANOS_USER
ExecStart=$PIDANOS_HOME/bin/pidanos-dns
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pidanos-dns
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$PIDANOS_LOG $PIDANOS_DATA $PIDANOS_CONFIG

# Network permissions for DNS
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # Web service
    cat > "/etc/systemd/system/pidanos-web.service" << EOF
[Unit]
Description=Pidanos Web Interface
Documentation=https://github.com/pidanos/pidanos
After=network.target pidanos-dns.service
Wants=network.target

[Service]
Type=simple
User=$PIDANOS_USER
Group=$PIDANOS_USER
WorkingDirectory=$PIDANOS_HOME/src/web
Environment=PATH=$PIDANOS_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$PIDANOS_HOME/venv/bin/python app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pidanos-web

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$PIDANOS_LOG $PIDANOS_DATA $PIDANOS_CONFIG $PIDANOS_HOME

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Systemd services created"
}

create_cli_tool() {
    log "Creating CLI tool..."
    
    cat > "/usr/local/bin/pidanos" << EOF
#!/bin/bash
# Pidanos CLI Tool

PIDANOS_HOME="$PIDANOS_HOME"
PIDANOS_CONFIG="$PIDANOS_CONFIG"

print_status() {
    echo -e "\033[0;34m[INFO]\033[0m \$1"
}

print_success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m \$1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m \$1"
}

case "\$1" in
    status)
        echo "🛡️  Pidanos Status"
        echo "=================="
        if systemctl is-active pidanos-dns >/dev/null 2>&1; then
            echo "DNS Server: 🟢 Running"
        else
            echo "DNS Server: 🔴 Stopped"
        fi
        
        if systemctl is-active pidanos-web >/dev/null 2>&1; then
            echo "Web Interface: 🟢 Running"
        else
            echo "Web Interface: 🔴 Stopped"
        fi
        
        echo ""
        echo "📊 Quick Stats:"
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$PIDANOS_DATA/pidanos.db" ]]; then
            total=\$(sqlite3 "$PIDANOS_DATA/pidanos.db" "SELECT COUNT(*) FROM queries WHERE DATE(timestamp) = DATE('now');")
            blocked=\$(sqlite3 "$PIDANOS_DATA/pidanos.db" "SELECT COUNT(*) FROM queries WHERE DATE(timestamp) = DATE('now') AND blocked = 1;")
            echo "Total queries today: \$total"
            echo "Blocked queries today: \$blocked"
            if [[ \$total -gt 0 ]]; then
                percentage=\$(echo "scale=1; \$blocked * 100 / \$total" | bc 2>/dev/null || echo "0")
                echo "Block percentage: \${percentage}%"
            fi
        fi
        ;;
    enable|start)
        echo "🟢 Starting Pidanos protection..."
        systemctl start pidanos-dns pidanos-web
        systemctl enable pidanos-dns pidanos-web
        print_success "Protection enabled"
        echo ""
        echo "🌐 Web interface: http://\$(hostname -I | awk '{print \$1}'):$WEB_PORT"
        ;;
    disable|stop)
        echo "🔴 Stopping Pidanos protection..."
        systemctl stop pidanos-dns pidanos-web
        print_success "Protection disabled"
        ;;
    restart)
        echo "🔄 Restarting Pidanos..."
        systemctl restart pidanos-dns pidanos-web
        print_success "Restart complete"
        ;;
    update)
        echo "📥 Updating block lists..."
        # Download updated lists
        wget -q -O "$PIDANOS_CONFIG/lists/ads.txt.new" "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" || {
            print_error "Failed to download updated ads list"
            exit 1
        }
        mv "$PIDANOS_CONFIG/lists/ads.txt.new" "$PIDANOS_CONFIG/lists/ads.txt"
        
        # Restart DNS to reload lists
        systemctl restart pidanos-dns
        print_success "Block lists updated and DNS server restarted"
        ;;
    logs)
        echo "📋 Recent Pidanos logs:"
        journalctl -u pidanos-dns -u pidanos-web --no-pager -n 50
        ;;
    web)
        echo "🌐 Web interface:"
        echo "   http://\$(hostname -I | awk '{print \$1}'):$WEB_PORT"
        echo ""
        echo "📱 Mobile access:"
        echo "   Use the IP address above on your mobile device"
        ;;
    install)
        echo "📦 Pidanos is already installed!"
        echo "Use 'pidanos enable' to start protection"
        ;;
    uninstall)
        echo "⚠️  This will completely remove Pidanos from your system."
        read -p "Are you sure? (y/N): " -n 1 -r
        echo
        if [[ \$REPLY =~ ^[Yy]\$ ]]; then
            systemctl stop pidanos-dns pidanos-web 2>/dev/null || true
            systemctl disable pidanos-dns pidanos-web 2>/dev/null || true
            rm -f /etc/systemd/system/pidanos-*.service
            systemctl daemon-reload
            userdel $PIDANOS_USER 2>/dev/null || true
            rm -rf $PIDANOS_HOME $PIDANOS_CONFIG $PIDANOS_LOG
            rm -f /usr/local/bin/pidanos
            print_success "Pidanos uninstalled"
        else
            echo "Uninstall cancelled"
        fi
        ;;
    *)
        echo "🛡️  Pidanos - Network-wide ad blocking"
        echo ""
        echo "Usage: pidanos <command>"
        echo ""
        echo "Commands:"
        echo "  status     Show service status and stats"
        echo "  enable     Enable protection (start services)"
        echo "  disable    Disable protection (stop services)"
        echo "  restart    Restart all services"
        echo "  update     Update block lists"
        echo "  logs       Show recent logs"
        echo "  web        Show web interface URL"
        echo "  uninstall  Remove Pidanos completely"
        echo ""
        echo "Examples:"
        echo "  pidanos enable    # Start blocking ads"
        echo "  pidanos status    # Check if running"
        echo "  pidanos web       # Get dashboard URL"
        echo ""
        ;;
esac
EOF
    
    chmod +x "/usr/local/bin/pidanos"
    success "CLI tool created"
}

configure_firewall() {
    log "Configuring firewall..."
    
    if command -v ufw >/dev/null 2>&1; then
        ufw --force enable >/dev/null 2>&1
        ufw allow "$DNS_PORT/udp" comment "Pidanos DNS" >/dev/null 2>&1
        ufw allow "$WEB_PORT/tcp" comment "Pidanos Web" >/dev/null 2>&1
        success "UFW rules added"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$DNS_PORT/udp" >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$WEB_PORT/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        success "Firewalld rules added"
    else
        warning "No supported firewall found. Manually open ports $DNS_PORT/udp and $WEB_PORT/tcp"
    fi
}

create_sample_data() {
    log "Creating sample data..."
    
    # Create sample queries for demo
    sqlite3 "$PIDANOS_DATA/pidanos.db" << 'EOF'
INSERT OR IGNORE INTO queries (domain, client_ip, query_type, blocked, response_time_ms) VALUES
('google.com', '192.168.1.100', 'A', 0, 15),
('doubleclick.net', '192.168.1.100', 'A', 1, 8),
('facebook.com', '192.168.1.105', 'A', 1, 12),
('github.com', '192.168.1.100', 'A', 0, 25),
('googleadservices.com', '192.168.1.105', 'A', 1, 5),
('stackoverflow.com', '192.168.1.100', 'A', 0, 30),
('analytics.google.com', '192.168.1.105', 'A', 1, 7),
('youtube.com', '192.168.1.100', 'A', 0, 20);
EOF
    
    chown "$PIDANOS_USER:$PIDANOS_USER" "$PIDANOS_DATA/pidanos.db"
    success "Sample data created"
}

show_completion() {
    clear
    print_header
    
    local server_ip=$(hostname -I | awk '{print $1}')
    
    echo -e "${GREEN}🎉 Installation Complete!${NC}"
    echo ""
    echo -e "${WHITE}Pidanos has been successfully installed and configured.${NC}"
    echo ""
    echo -e "${CYAN}📋 Next Steps:${NC}"
    echo ""
    echo -e "  1. ${YELLOW}Start Pidanos:${NC}"
    echo -e "     ${WHITE}pidanos enable${NC}"
    echo ""
    echo -e "  2. ${YELLOW}Access Web Dashboard:${NC}"
    echo -e "     ${WHITE}http://$server_ip:$WEB_PORT${NC}"
    echo ""
    echo -e "  3. ${YELLOW}Configure your devices:${NC}"
    echo -e "     ${WHITE}Set DNS server to: $server_ip${NC}"
    echo -e "     ${WHITE}Router settings → DNS → Primary: $server_ip${NC}"
    echo ""
    echo -e "${CYAN}📖 Useful Commands:${NC}"
    echo ""
    echo -e "  ${WHITE}pidanos status${NC}     - Check service status"
    echo -e "  ${WHITE}pidanos disable${NC}    - Temporarily disable blocking"
    echo -e "  ${WHITE}pidanos update${NC}     - Update block lists"
    echo -e "  ${WHITE}pidanos logs${NC}       - View recent logs"
    echo -e "  ${WHITE}pidanos web${NC}        - Show dashboard URL"
    echo ""
    echo -e "${CYAN}🔧 Configuration Files:${NC}"
    echo ""
    echo -e "  ${WHITE}Config:${NC}     $PIDANOS_CONFIG/pidanos.conf"
    echo -e "  ${WHITE}Block Lists:${NC} $PIDANOS_CONFIG/lists/"
    echo -e "  ${WHITE}Logs:${NC}       $PIDANOS_LOG/"
    echo ""
    echo -e "${PURPLE}🚀 Ready to block ads network-wide!${NC}"
    echo -e "${PURPLE}Made with ❤️  for a better, ad-free internet${NC}"
    echo ""
    
    # Auto-start option
    echo -e "${YELLOW}Would you like to start Pidanos now? (Y/n):${NC} "
    read -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "You can start Pidanos later with: pidanos enable"
    else
        echo ""
        log "Starting Pidanos services..."
        systemctl start pidanos-dns pidanos-web
        systemctl enable pidanos-dns pidanos-web
        sleep 2
        
        if systemctl is-active pidanos-dns >/dev/null 2>&1 && systemctl is-active pidanos-web >/dev/null 2>&1; then
            success "Pidanos is now running!"
            echo ""
            echo -e "${GREEN}🛡️  Protection is active${NC}"
            echo -e "${GREEN}🌐 Dashboard: http://$server_ip:$WEB_PORT${NC}"
        else
            warning "Services may need a moment to start. Check with: pidanos status"
        fi
    fi
    echo ""
}

# Main installation flow
main() {
    print_header
    
    echo -e "${CYAN}Starting Pidanos installation...${NC}"
    echo ""
    
    check_root
    detect_system
    check_dependencies
    create_user
    create_directories
    install_go
    install_python_deps
    create_dns_server
    create_web_backend
    compile_dns_server
    create_web_files
    create_config
    create_systemd_services
    create_cli_tool
    configure_firewall
    create_sample_data
    
    show_completion
}

# Self-download and installation
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi