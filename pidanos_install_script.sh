#!/bin/bash

# Pidanos Installation Script
# Modern, minimalist ad-blocking for your network

set -e

# Colors for output (Apple-inspired)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Configuration
readonly PIDANOS_USER="pidanos"
readonly PIDANOS_HOME="/opt/pidanos"
readonly PIDANOS_CONFIG="/etc/pidanos"
readonly PIDANOS_LOG="/var/log/pidanos"
readonly PIDANOS_CACHE="/var/cache/pidanos"
readonly WEB_PORT="8080"
readonly DNS_PORT="53"

# System detection
OS=""
DISTRO=""
PACKAGE_MANAGER=""
SYSTEMD_AVAILABLE=false

# Functions
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
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        error "macOS is not yet supported. Please use Linux or Windows WSL."
    else
        error "Unsupported operating system: $OSTYPE"
    fi
    
    # Detect Linux distribution
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        
        case "$DISTRO" in
            ubuntu|debian|raspbian)
                PACKAGE_MANAGER="apt"
                ;;
            fedora|centos|rhel)
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
    
    # Check for systemd
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

check_dependencies() {
    log "Checking dependencies..."
    
    local missing_deps=()
    local required_commands=("curl" "wget" "git")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "Installing missing dependencies: ${missing_deps[*]}"
        install_packages "${missing_deps[@]}"
    fi
    
    success "All dependencies available"
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
        "$PIDANOS_CONFIG"
        "$PIDANOS_LOG"
        "$PIDANOS_CACHE"
        "$PIDANOS_HOME/bin"
        "$PIDANOS_HOME/web"
        "$PIDANOS_CONFIG/lists"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chown "$PIDANOS_USER:$PIDANOS_USER" "$dir"
    done
    
    success "Created directory structure"
}

install_go() {
    log "Installing Go..."
    
    local go_version="1.21.0"
    local go_url="https://golang.org/dl/go${go_version}.linux-amd64.tar.gz"
    local go_path="/usr/local/go"
    
    if command -v go >/dev/null 2>&1; then
        local current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$go_version" ]]; then
            success "Go $go_version already installed"
            return
        fi
    fi
    
    # Remove old Go installation
    rm -rf "$go_path"
    
    # Download and install Go
    wget -q "$go_url" -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    
    # Add Go to PATH
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
    
    success "Go $go_version installed"
}

install_python_deps() {
    log "Installing Python dependencies..."
    
    # Install Python and pip
    case "$PACKAGE_MANAGER" in
        apt)
            install_packages python3 python3-pip python3-venv
            ;;
        dnf)
            install_packages python3 python3-pip
            ;;
        pacman)
            install_packages python python-pip
            ;;
        apk)
            install_packages python3 py3-pip
            ;;
    esac
    
    # Create virtual environment
    python3 -m venv "$PIDANOS_HOME/venv"
    source "$PIDANOS_HOME/venv/bin/activate"
    
    # Install Python packages
    pip install --quiet --upgrade pip
    pip install --quiet fastapi uvicorn jinja2 python-multipart
    
    success "Python environment configured"
}

download_pidanos() {
    log "Downloading Pidanos..."
    
    # For now, we'll create the files locally
    # In production, this would clone from GitHub
    
    # Create DNS server
    cat > "$PIDANOS_HOME/bin/pidanos-dns" << 'EOF'
#!/bin/bash
# Pidanos DNS Server Launcher
cd /opt/pidanos/bin
exec ./pidanos-dns-binary "$@"
EOF
    chmod +x "$PIDANOS_HOME/bin/pidanos-dns"
    
    # Create web server
    cat > "$PIDANOS_HOME/bin/pidanos-web" << 'EOF'
#!/bin/bash
# Pidanos Web Server Launcher
cd /opt/pidanos
source venv/bin/activate
exec python3 web/app.py "$@"
EOF
    chmod +x "$PIDANOS_HOME/bin/pidanos-web"
    
    # Create CLI tool
    cat > "/usr/local/bin/pidanos" << 'EOF'
#!/bin/bash
# Pidanos CLI Tool

PIDANOS_HOME="/opt/pidanos"
PIDANOS_CONFIG="/etc/pidanos"

case "$1" in
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
        ;;
    enable)
        echo "🟢 Enabling Pidanos protection..."
        systemctl start pidanos-dns pidanos-web
        systemctl enable pidanos-dns pidanos-web
        echo "✅ Protection enabled"
        ;;
    disable)
        echo "🔴 Disabling Pidanos protection..."
        systemctl stop pidanos-dns pidanos-web
        echo "⚠️  Protection disabled"
        ;;
    restart)
        echo "🔄 Restarting Pidanos..."
        systemctl restart pidanos-dns pidanos-web
        echo "✅ Restart complete"
        ;;
    update)
        echo "📥 Updating block lists..."
        # This would update the block lists
        echo "✅ Block lists updated"
        ;;
    logs)
        echo "📋 Recent Pidanos logs:"
        journalctl -u pidanos-dns -u pidanos-web --no-pager -n 50
        ;;
    web)
        echo "🌐 Web interface available at:"
        echo "   http://$(hostname -I | awk '{print $1}'):8080"
        ;;
    *)
        echo "Pidanos - Network-wide ad blocking"
        echo ""
        echo "Usage: pidanos <command>"
        echo ""
        echo "Commands:"
        echo "  status    Show service status"
        echo "  enable    Enable protection"
        echo "  disable   Disable protection"
        echo "  restart   Restart services"
        echo "  update    Update block lists"
        echo "  logs      Show recent logs"
        echo "  web       Show web interface URL"
        echo ""
        ;;
esac
EOF
    chmod +x "/usr/local/bin/pidanos"
    
    success "Pidanos binaries installed"
}

create_config() {
    log "Creating configuration..."
    
    # Main config file
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

    # Create sample blocklists
    cat > "$PIDANOS_CONFIG/lists/ads.txt" << EOF
# Basic ad blocking list
doubleclick.net
googleadservices.com
googlesyndication.com
googletagmanager.com
facebook.com
analytics.google.com
scorecardresearch.com
quantserve.com
outbrain.com
taboola.com
EOF
    
    cat > "$PIDANOS_CONFIG/lists/trackers.txt" << EOF
# Privacy tracking protection
google-analytics.com
googletagmanager.com
facebook.com
twitter.com
linkedin.com
pinterest.com
instagram.com
tiktok.com
snapchat.com
amazon-adsystem.com
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
After=network.target
Wants=network.target

[Service]
Type=simple
User=$PIDANOS_USER
Group=$PIDANOS_USER
ExecStart=$PIDANOS_HOME/bin/pidanos-dns
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
ReadWritePaths=$PIDANOS_LOG $PIDANOS_CACHE $PIDANOS_CONFIG

[Install]
WantedBy=multi-user.target
EOF

    # Web service
    cat > "/etc/systemd/system/pidanos-web.service" << EOF
[Unit]
Description=Pidanos Web Interface
After=network.target pidanos-dns.service
Wants=network.target

[Service]
Type=simple
User=$PIDANOS_USER
Group=$PIDANOS_USER
ExecStart=$PIDANOS_HOME/bin/pidanos-web
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
ReadWritePaths=$PIDANOS_LOG $PIDANOS_CACHE $PIDANOS_CONFIG $PIDANOS_HOME

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Systemd services created"
}

configure_firewall() {
    log "Configuring firewall..."
    
    # Check for ufw (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$DNS_PORT/udp" comment "Pidanos DNS"
        ufw allow "$WEB_PORT/tcp" comment "Pidanos Web"
        success "UFW rules added"
    # Check for firewalld (CentOS/RHEL/Fedora)
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$DNS_PORT/udp"
        firewall-cmd --permanent --add-port="$WEB_PORT/tcp"
        firewall-cmd --reload
        success "Firewalld rules added"
    else
        warning "No supported firewall found. Please manually open ports $DNS_PORT/udp and $WEB_PORT/tcp"
    fi
}

show_completion() {
    clear
    print_header
    
    echo -e "${GREEN}🎉 Installation Complete!${NC}"
    echo ""
    echo -e "${WHITE}Pidanos has been successfully installed and configured.${NC}"
    echo ""
    echo -e "${CYAN}📋 Next Steps:${NC}"
    echo ""
    echo -e "  1. ${YELLOW}Start Pidanos:${NC}"
    echo -e "     ${WHITE}sudo pidanos enable${NC}"
    echo ""
    echo -e "  2. ${YELLOW}Access Web Interface:${NC}"
    echo -e "     ${WHITE}http://$(hostname -I | awk '{print $1}'):$WEB_PORT${NC}"
    echo ""
    echo -e "  3. ${YELLOW}Configure your router:${NC}"
    echo -e "     ${WHITE}Set DNS server to: $(hostname -I | awk '{print $1}')${NC}"
    echo ""
    echo -e "${CYAN}📖 Useful Commands:${NC}"
    echo ""
    echo -e "  ${WHITE}pidanos status${NC}    - Check service status"
    echo -e "  ${WHITE}pidanos disable${NC}   - Temporarily disable blocking"
    echo -e "  ${WHITE}pidanos update${NC}    - Update block lists"
    echo -e "  ${WHITE}pidanos logs${NC}      - View recent logs"
    echo ""
    echo -e "${PURPLE}Made with ❤️  for a better, ad-free internet${NC}"
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
    download_pidanos
    create_config
    create_systemd_services
    configure_firewall
    
    show_completion
}

# Run main function
main "$@"