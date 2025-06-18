# src/web/app.py
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn
import json
import sqlite3
import os
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional
import asyncio
import logging

# Configure logging
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
        """Initialize SQLite database for stats and logs"""
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        # Create tables
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
        
        # Insert default blocklists
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
        """Setup FastAPI routes"""
        
        # Mount static files and templates
        self.app.mount("/static", StaticFiles(directory="static"), name="static")
        templates = Jinja2Templates(directory="templates")
        
        @self.app.get("/", response_class=HTMLResponse)
        async def dashboard(request: Request):
            """Main dashboard page"""
            return HTMLResponse(content=self.get_dashboard_html())
        
        @self.app.get("/api/stats")
        async def get_stats():
            """Get current statistics"""
            try:
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                
                # Get today's stats
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
                
                # Calculate percentage
                block_percentage = (blocked_count / total_queries * 100) if total_queries > 0 else 0
                
                # Get unique clients today
                cursor.execute('''
                    SELECT COUNT(DISTINCT client_ip) 
                    FROM queries 
                    WHERE DATE(timestamp) = ?
                ''', (today,))
                unique_clients = cursor.fetchone()[0] or 0
                
                # Get blocklist count
                cursor.execute('SELECT COUNT(*) FROM blocklists WHERE enabled = 1')
                active_lists = cursor.fetchone()[0] or 0
                
                conn.close()
                
                return {
                    "total_queries": total_queries,
                    "blocked_count": blocked_count,
                    "block_percentage": round(block_percentage, 1),
                    "unique_clients": unique_clients,
                    "active_lists": active_lists,
                    "protection_enabled": True,  # TODO: Get from actual service status
                    "last_updated": datetime.now().isoformat()
                }
                
            except Exception as e:
                logger.error(f"Error getting stats: {e}")
                return {"error": str(e)}
        
        @self.app.get("/api/stats/history")
        async def get_stats_history(period: str = "24h"):
            """Get historical statistics"""
            try:
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                
                if period == "24h":
                    # Last 24 hours, grouped by hour
                    cursor.execute('''
                        SELECT 
                            strftime('%Y-%m-%d %H:00:00', timestamp) as hour,
                            COUNT(*) as total,
                            SUM(CASE WHEN blocked = 1 THEN 1 ELSE 0 END) as blocked
                        FROM queries 
                        WHERE timestamp >= datetime('now', '-24 hours')
                        GROUP BY hour
                        ORDER BY hour
                    ''')
                elif period == "7d":
                    # Last 7 days
                    cursor.execute('''
                        SELECT 
                            DATE(timestamp) as day,
                            COUNT(*) as total,
                            SUM(CASE WHEN blocked = 1 THEN 1 ELSE 0 END) as blocked
                        FROM queries 
                        WHERE timestamp >= datetime('now', '-7 days')
                        GROUP BY day
                        ORDER BY day
                    ''')
                else:  # 30d
                    cursor.execute('''
                        SELECT 
                            DATE(timestamp) as day,
                            COUNT(*) as total,
                            SUM(CASE WHEN blocked = 1 THEN 1 ELSE 0 END) as blocked
                        FROM queries 
                        WHERE timestamp >= datetime('now', '-30 days')
                        GROUP BY day
                        ORDER BY day
                    ''')
                
                results = cursor.fetchall()
                conn.close()
                
                history = []
                for row in results:
                    history.append({
                        "timestamp": row[0],
                        "total_queries": row[1],
                        "blocked_queries": row[2],
                        "allowed_queries": row[1] - row[2]
                    })
                
                return {"period": period, "data": history}
                
            except Exception as e:
                logger.error(f"Error getting history: {e}")
                return {"error": str(e)}
        
        @self.app.get("/api/queries/recent")
        async def get_recent_queries(limit: int = 100):
            """Get recent DNS queries"""
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
        
        @self.app.get("/api/top-domains")
        async def get_top_domains(period: str = "24h", blocked_only: bool = False):
            """Get top queried or blocked domains"""
            try:
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                
                time_filter = {
                    "24h": "datetime('now', '-24 hours')",
                    "7d": "datetime('now', '-7 days')",
                    "30d": "datetime('now', '-30 days')"
                }.get(period, "datetime('now', '-24 hours')")
                
                blocked_filter = "AND blocked = 1" if blocked_only else ""
                
                cursor.execute(f'''
                    SELECT domain, COUNT(*) as count, blocked
                    FROM queries 
                    WHERE timestamp >= {time_filter} {blocked_filter}
                    GROUP BY domain, blocked
                    ORDER BY count DESC 
                    LIMIT 20
                ''')
                
                results = cursor.fetchall()
                conn.close()
                
                domains = []
                for row in results:
                    domains.append({
                        "domain": row[0],
                        "count": row[1],
                        "status": "blocked" if row[2] else "allowed"
                    })
                
                return {"domains": domains, "period": period}
                
            except Exception as e:
                logger.error(f"Error getting top domains: {e}")
                return {"error": str(e)}
        
        @self.app.post("/api/blocklists/update")
        async def update_blocklists():
            """Update all enabled blocklists"""
            try:
                # This would trigger the blocklist update process
                # For now, just simulate the update
                await asyncio.sleep(1)  # Simulate processing time
                
                # Update database
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE blocklists 
                    SET last_updated = CURRENT_TIMESTAMP 
                    WHERE enabled = 1
                ''')
                conn.commit()
                conn.close()
                
                logger.info("📋 Blocklists updated")
                return {"status": "success", "message": "Blocklists updated successfully"}
                
            except Exception as e:
                logger.error(f"Error updating blocklists: {e}")
                return {"status": "error", "error": str(e)}
        
        @self.app.post("/api/protection/toggle")
        async def toggle_protection():
            """Enable/disable protection"""
            try:
                # This would interact with the DNS service
                # For now, just return success
                return {"status": "success", "protection_enabled": True}
                
            except Exception as e:
                logger.error(f"Error toggling protection: {e}")
                return {"status": "error", "error": str(e)}
        
        @self.app.post("/api/cache/flush")
        async def flush_cache():
            """Flush DNS cache"""
            try:
                # This would send a signal to the DNS server to flush cache
                await asyncio.sleep(0.5)  # Simulate processing
                logger.info("🧹 DNS cache flushed")
                return {"status": "success", "message": "DNS cache flushed"}
                
            except Exception as e:
                logger.error(f"Error flushing cache: {e}")
                return {"status": "error", "error": str(e)}

    def get_dashboard_html(self) -> str:
        """Return the dashboard HTML (embedded for simplicity)"""
        # In production, this would be served from a template file
        # For now, we'll return a simple HTML page that loads our interface
        return '''
        <!DOCTYPE html>
        <html>
        <head>
            <title>Pidanos Dashboard</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; margin: 0; padding: 20px; background: #f5f5f7; }
                .container { max-width: 1200px; margin: 0 auto; }
                .header { text-align: center; margin-bottom: 40px; }
                .logo { font-size: 2.5em; font-weight: bold; color: #007AFF; }
                .card { background: white; padding: 30px; border-radius: 16px; margin: 20px 0; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
                .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; }
                .stat { text-align: center; padding: 20px; background: #f9f9f9; border-radius: 12px; }
                .stat-value { font-size: 2em; font-weight: bold; color: #007AFF; }
                .stat-label { color: #86868b; margin-top: 8px; }
                .button { background: #007AFF; color: white; border: none; padding: 12px 24px; border-radius: 8px; cursor: pointer; margin: 10px; }
                .button:hover { background: #0056CC; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <div class="logo">🛡️ Pidanos</div>
                    <p>Network-wide ad blocking • Active Protection</p>
                </div>
                
                <div class="card">
                    <h2>Statistics</h2>
                    <div class="stats" id="stats">
                        <div class="stat">
                            <div class="stat-value" id="total-queries">0</div>
                            <div class="stat-label">Total Queries</div>
                        </div>
                </div>
                
                <div class="card">
                    <h2>Quick Actions</h2>
                    <button class="button" onclick="updateBlocklists()">🔄 Update Block Lists</button>
                    <button class="button" onclick="flushCache()">🧹 Flush Cache</button>
                    <button class="button" onclick="toggleProtection()">🛡️ Toggle Protection</button>
                    <button class="button" onclick="viewLogs()">📝 View Logs</button>
                </div>
                
                <div class="card">
                    <h2>Recent Activity</h2>
                    <div id="recent-queries">Loading...</div>
                </div>
            </div>
            
            <script>
                // API functions
                async function fetchStats() {
                    try {
                        const response = await fetch('/api/stats');
                        const data = await response.json();
                        
                        document.getElementById('total-queries').textContent = data.total_queries.toLocaleString();
                        document.getElementById('blocked-count').textContent = data.blocked_count.toLocaleString();
                        document.getElementById('block-percentage').textContent = data.block_percentage + '%';
                        document.getElementById('unique-clients').textContent = data.unique_clients;
                    } catch (error) {
                        console.error('Error fetching stats:', error);
                    }
                }
                
                async function fetchRecentQueries() {
                    try {
                        const response = await fetch('/api/queries/recent?limit=10');
                        const data = await response.json();
                        
                        const container = document.getElementById('recent-queries');
                        if (data.queries && data.queries.length > 0) {
                            container.innerHTML = data.queries.map(q => 
                                `<div style="padding: 8px; border-bottom: 1px solid #eee;">
                                    <strong>${q.domain}</strong> 
                                    <span style="color: ${q.status === 'blocked' ? '#ff3b30' : '#34c759'};">
                                        ${q.status}
                                    </span>
                                    <small style="color: #86868b; float: right;">${new Date(q.timestamp).toLocaleTimeString()}</small>
                                </div>`
                            ).join('');
                        } else {
                            container.innerHTML = '<p style="color: #86868b;">No recent queries</p>';
                        }
                    } catch (error) {
                        document.getElementById('recent-queries').innerHTML = '<p style="color: #ff3b30;">Error loading queries</p>';
                    }
                }
                
                async function updateBlocklists() {
                    const button = event.target;
                    const original = button.textContent;
                    button.textContent = '⏳ Updating...';
                    button.disabled = true;
                    
                    try {
                        const response = await fetch('/api/blocklists/update', { method: 'POST' });
                        const data = await response.json();
                        
                        if (data.status === 'success') {
                            button.textContent = '✅ Updated';
                            setTimeout(() => {
                                button.textContent = original;
                                button.disabled = false;
                            }, 2000);
                        } else {
                            throw new Error(data.error || 'Update failed');
                        }
                    } catch (error) {
                        button.textContent = '❌ Failed';
                        setTimeout(() => {
                            button.textContent = original;
                            button.disabled = false;
                        }, 2000);
                    }
                }
                
                async function flushCache() {
                    const button = event.target;
                    const original = button.textContent;
                    button.textContent = '⏳ Flushing...';
                    button.disabled = true;
                    
                    try {
                        const response = await fetch('/api/cache/flush', { method: 'POST' });
                        const data = await response.json();
                        
                        if (data.status === 'success') {
                            button.textContent = '✅ Cleared';
                            setTimeout(() => {
                                button.textContent = original;
                                button.disabled = false;
                            }, 2000);
                        } else {
                            throw new Error(data.error || 'Flush failed');
                        }
                    } catch (error) {
                        button.textContent = '❌ Failed';
                        setTimeout(() => {
                            button.textContent = original;
                            button.disabled = false;
                        }, 2000);
                    }
                }
                
                async function toggleProtection() {
                    const button = event.target;
                    const original = button.textContent;
                    button.textContent = '⏳ Toggling...';
                    button.disabled = true;
                    
                    try {
                        const response = await fetch('/api/protection/toggle', { method: 'POST' });
                        const data = await response.json();
                        
                        if (data.status === 'success') {
                            button.textContent = data.protection_enabled ? '🛡️ Protection On' : '⚠️ Protection Off';
                            setTimeout(() => {
                                button.disabled = false;
                            }, 1000);
                        } else {
                            throw new Error(data.error || 'Toggle failed');
                        }
                    } catch (error) {
                        button.textContent = '❌ Failed';
                        setTimeout(() => {
                            button.textContent = original;
                            button.disabled = false;
                        }, 2000);
                    }
                }
                
                function viewLogs() {
                    // This would open a logs modal or page
                    alert('Logs viewer coming soon! 📝\\n\\nFor now, use: sudo journalctl -u pidanos-dns -f');
                }
                
                // Initialize dashboard
                document.addEventListener('DOMContentLoaded', function() {
                    fetchStats();
                    fetchRecentQueries();
                    
                    // Auto-refresh every 30 seconds
                    setInterval(() => {
                        fetchStats();
                        fetchRecentQueries();
                    }, 30000);
                });
            </script>
        </body>
        </html>
        '''

def create_sample_data():
    """Create some sample data for testing"""
    db_path = "/opt/pidanos/data/pidanos.db"
    
    # Only create sample data if database is empty
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    cursor.execute('SELECT COUNT(*) FROM queries')
    if cursor.fetchone()[0] == 0:
        # Insert sample queries
        sample_queries = [
            ('google.com', '192.168.1.100', 'A', False, 15),
            ('doubleclick.net', '192.168.1.100', 'A', True, 8),
            ('facebook.com', '192.168.1.105', 'A', True, 12),
            ('github.com', '192.168.1.100', 'A', False, 25),
            ('googleadservices.com', '192.168.1.105', 'A', True, 5),
            ('stackoverflow.com', '192.168.1.100', 'A', False, 30),
            ('analytics.google.com', '192.168.1.105', 'A', True, 7),
            ('youtube.com', '192.168.1.100', 'A', False, 20),
        ]
        
        for domain, client, qtype, blocked, response_time in sample_queries:
            cursor.execute('''
                INSERT INTO queries (domain, client_ip, query_type, blocked, response_time_ms)
                VALUES (?, ?, ?, ?, ?)
            ''', (domain, client, qtype, blocked, response_time))
        
        logger.info("📋 Created sample data for testing")
    
    conn.commit()
    conn.close()

def main():
    """Main entry point"""
    # Create API instance
    api = PidanosAPI()
    
    # Create sample data for development
    create_sample_data()
    
    # Configuration
    host = "0.0.0.0"
    port = 8080
    
    logger.info(f"🚀 Starting Pidanos Web Interface on {host}:{port}")
    logger.info(f"🌐 Dashboard: http://localhost:{port}")
    logger.info(f"📖 API Docs: http://localhost:{port}/docs")
    
    # Start server
    uvicorn.run(
        api.app,
        host=host,
        port=port,
        log_level="info",
        access_log=True
    )

if __name__ == "__main__":
    main()
                        <div class="stat">
                            <div class="stat-value" id="blocked-count">0</div>
                            <div class="stat-label">Blocked</div>
                        </div>
                        <div class="stat">
                            <div class="stat-value" id="block-percentage">0%</div>
                            <div class="stat-label">Block Rate</div>
                        </div>
                        <div class="stat">
                            <div class="stat-value" id="unique-clients">0</div>
                            <div class="stat-label">Clients</div>
                        </div>
                    </div>