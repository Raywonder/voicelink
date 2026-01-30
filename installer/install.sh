#!/bin/bash
#
# VoiceLink Server Installer
# Installs VoiceLink voice chat server with all dependencies
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VOICELINK_VERSION="1.0.0"
MAIN_SERVER="https://voicelink.devinecreations.net"
DEFAULT_PORT=3010
INSTALL_DIR="${VOICELINK_INSTALL_DIR:-$HOME/voicelink}"

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           VoiceLink Server Installer v${VOICELINK_VERSION}            ║"
echo "║          Decentralized Voice Chat Platform               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check for Node.js
check_node() {
    echo -e "${YELLOW}Checking Node.js...${NC}"
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -ge 18 ]; then
            echo -e "${GREEN}✓ Node.js $(node -v) found${NC}"
            return 0
        fi
    fi
    echo -e "${RED}✗ Node.js 18+ required${NC}"
    echo "Install with: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs"
    exit 1
}

# Check for PM2
check_pm2() {
    echo -e "${YELLOW}Checking PM2...${NC}"
    if command -v pm2 &> /dev/null; then
        echo -e "${GREEN}✓ PM2 found${NC}"
    else
        echo -e "${YELLOW}Installing PM2...${NC}"
        npm install -g pm2
        echo -e "${GREEN}✓ PM2 installed${NC}"
    fi
}

# Check for Ollama (optional)
check_ollama() {
    echo -e "${YELLOW}Checking Ollama (optional for local docs)...${NC}"
    if command -v ollama &> /dev/null; then
        echo -e "${GREEN}✓ Ollama found - local doc generation available${NC}"
        OLLAMA_AVAILABLE=true
    else
        echo -e "${YELLOW}○ Ollama not found - docs will sync from main server${NC}"
        OLLAMA_AVAILABLE=false
    fi
}

# Create installation directory
setup_directories() {
    echo -e "${YELLOW}Setting up directories...${NC}"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/data/backups"
    mkdir -p "$INSTALL_DIR/docs/public"
    mkdir -p "$INSTALL_DIR/docs/authenticated"
    mkdir -p "$INSTALL_DIR/logs"
    echo -e "${GREEN}✓ Directories created at $INSTALL_DIR${NC}"
}

# Download and extract VoiceLink
download_voicelink() {
    echo -e "${YELLOW}Downloading VoiceLink...${NC}"

    cd "$INSTALL_DIR"

    # If git is available, clone the repo
    if command -v git &> /dev/null; then
        if [ -d ".git" ]; then
            echo "Updating existing installation..."
            git pull origin main 2>/dev/null || true
        else
            git clone https://github.com/devinecreations/voicelink-local.git . 2>/dev/null || {
                # Fallback: download release tarball
                echo "Git clone failed, downloading release..."
                curl -sL "$MAIN_SERVER/releases/latest.tar.gz" | tar xz --strip-components=1
            }
        fi
    else
        # Download release tarball
        curl -sL "$MAIN_SERVER/releases/latest.tar.gz" | tar xz --strip-components=1 2>/dev/null || {
            echo -e "${RED}Failed to download VoiceLink${NC}"
            exit 1
        }
    fi

    echo -e "${GREEN}✓ VoiceLink downloaded${NC}"
}

# Install dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    cd "$INSTALL_DIR"
    npm install --production
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

# Generate configuration
generate_config() {
    echo -e "${YELLOW}Generating configuration...${NC}"

    # Get server name
    read -p "Server name [VoiceLink Node]: " SERVER_NAME
    SERVER_NAME="${SERVER_NAME:-VoiceLink Node}"

    # Get port
    read -p "Port [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"

    # Get public URL
    read -p "Public URL (optional, e.g., https://node2.voicelink.example.com): " PUBLIC_URL

    # Enable federation?
    read -p "Enable federation with main network? [Y/n]: " FEDERATION
    FEDERATION="${FEDERATION:-Y}"

    # Create deploy.json
    cat > "$INSTALL_DIR/data/deploy.json" << EOF
{
    "version": "$VOICELINK_VERSION",
    "server": {
        "name": "$SERVER_NAME",
        "description": "VoiceLink voice chat node",
        "port": $PORT,
        "host": "0.0.0.0",
        "publicUrl": ${PUBLIC_URL:+\"$PUBLIC_URL\"}${PUBLIC_URL:-null}
    },
    "federation": {
        "enabled": $([ "$FEDERATION" = "Y" ] || [ "$FEDERATION" = "y" ] && echo "true" || echo "false"),
        "mode": "spoke",
        "hubUrl": "$MAIN_SERVER"
    },
    "features": {
        "jukebox": true,
        "peekIntoRoom": true,
        "whisperMode": true
    },
    "installedAt": "$(date -Iseconds)",
    "installId": "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "node-$(date +%s)")"
}
EOF

    echo -e "${GREEN}✓ Configuration generated${NC}"
}

# Create quick start page
create_quickstart() {
    echo -e "${YELLOW}Creating quick start guide...${NC}"

    cat > "$INSTALL_DIR/docs/public/quickstart.html" << 'QUICKSTART'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VoiceLink Quick Start</title>
    <style>
        :root { --primary: #6364FF; --bg: #1a1a2e; --surface: #16213e; --text: #eee; }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; }
        .container { max-width: 600px; background: var(--surface); border-radius: 16px; padding: 40px; box-shadow: 0 20px 60px rgba(0,0,0,0.4); }
        h1 { color: var(--primary); margin-bottom: 10px; }
        .subtitle { color: #888; margin-bottom: 30px; }
        .step { background: rgba(99,100,255,0.1); border-left: 4px solid var(--primary); padding: 15px 20px; margin: 15px 0; border-radius: 0 8px 8px 0; }
        .step-num { display: inline-block; background: var(--primary); color: white; width: 28px; height: 28px; text-align: center; line-height: 28px; border-radius: 50%; margin-right: 10px; font-weight: bold; }
        code { background: rgba(0,0,0,0.3); padding: 3px 8px; border-radius: 4px; font-family: monospace; }
        .status { margin-top: 30px; padding: 20px; border-radius: 8px; }
        .status.loading { background: rgba(255,193,7,0.2); border: 1px solid #ffc107; }
        .status.ready { background: rgba(76,175,80,0.2); border: 1px solid #4caf50; }
        .btn { display: inline-block; background: var(--primary); color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; margin-top: 20px; transition: transform 0.2s; }
        .btn:hover { transform: translateY(-2px); }
        .spinner { display: inline-block; width: 20px; height: 20px; border: 2px solid #ffc107; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; margin-right: 10px; }
        @keyframes spin { to { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <h1>🎉 VoiceLink Installed!</h1>
        <p class="subtitle">Your voice chat node is ready</p>

        <div class="step">
            <span class="step-num">1</span>
            <strong>Server is running</strong> on port <code id="port">3010</code>
        </div>

        <div class="step">
            <span class="step-num">2</span>
            <strong>Join a room</strong> or create your own
        </div>

        <div class="step">
            <span class="step-num">3</span>
            <strong>Federation</strong> connects you to the global network
        </div>

        <div class="status loading" id="docs-status">
            <span class="spinner"></span>
            <span id="status-text">Syncing documentation from main server...</span>
        </div>

        <a href="/" class="btn">Open VoiceLink →</a>
        <a href="/admin/docs/admin-panel.html" class="btn" style="background: #563ACC; margin-left: 10px;">Admin Docs</a>
    </div>

    <script>
        // Check docs status
        async function checkDocs() {
            try {
                const res = await fetch('/api/docs/status');
                const data = await res.json();
                const statusEl = document.getElementById('docs-status');
                const textEl = document.getElementById('status-text');

                if (data.publicDocs > 0) {
                    statusEl.className = 'status ready';
                    textEl.textContent = `Documentation ready! ${data.publicDocs} public docs, ${data.authenticatedDocs} admin docs.`;
                } else if (data.generationInProgress) {
                    textEl.textContent = 'Generating documentation with Ollama...';
                    setTimeout(checkDocs, 5000);
                } else {
                    textEl.textContent = 'Documentation will sync shortly...';
                    setTimeout(checkDocs, 10000);
                }
            } catch (e) {
                setTimeout(checkDocs, 5000);
            }
        }
        checkDocs();
    </script>
</body>
</html>
QUICKSTART

    echo -e "${GREEN}✓ Quick start guide created${NC}"
}

# Create startup script with delayed doc sync
create_startup_script() {
    echo -e "${YELLOW}Creating startup script...${NC}"

    cat > "$INSTALL_DIR/start.sh" << 'STARTUP'
#!/bin/bash
# VoiceLink Startup Script

INSTALL_DIR="$(dirname "$(readlink -f "$0")")"
cd "$INSTALL_DIR"

# Start the server
echo "Starting VoiceLink server..."
pm2 start server/routes/local-server.js --name voicelink --cwd "$INSTALL_DIR" || {
    echo "PM2 start failed, trying node directly..."
    node server/routes/local-server.js &
}

# Wait for server to start
sleep 3

# Register with main server and schedule doc sync
echo "Registering with main network..."
(
    # Wait 20 minutes before syncing docs (gives main server time to detect)
    sleep 1200  # 20 minutes

    # Sync documentation
    echo "[$(date)] Syncing documentation..."
    node server/tools/docs-sync.js sync 2>&1 | tee -a logs/docs-sync.log

    echo "[$(date)] Documentation sync complete"
) &

echo ""
echo "VoiceLink is running!"
echo "  Local:  http://localhost:$(grep -o '"port": [0-9]*' data/deploy.json | grep -o '[0-9]*' || echo 3010)"
echo "  Docs will sync in 20 minutes"
echo ""
STARTUP

    chmod +x "$INSTALL_DIR/start.sh"
    echo -e "${GREEN}✓ Startup script created${NC}"
}

# Create PM2 ecosystem file
create_pm2_config() {
    echo -e "${YELLOW}Creating PM2 configuration...${NC}"

    cat > "$INSTALL_DIR/ecosystem.config.js" << EOF
module.exports = {
    apps: [{
        name: 'voicelink',
        script: 'server/routes/local-server.js',
        cwd: '$INSTALL_DIR',
        instances: 1,
        autorestart: true,
        watch: false,
        max_memory_restart: '500M',
        env: {
            NODE_ENV: 'production',
            VOICELINK_CONFIG_DIR: '$INSTALL_DIR/data'
        },
        error_file: '$INSTALL_DIR/logs/error.log',
        out_file: '$INSTALL_DIR/logs/output.log',
        log_date_format: 'YYYY-MM-DD HH:mm:ss'
    }]
};
EOF

    echo -e "${GREEN}✓ PM2 configuration created${NC}"
}

# Register with main server
register_node() {
    echo -e "${YELLOW}Registering with main server...${NC}"

    INSTALL_ID=$(grep -o '"installId": "[^"]*' "$INSTALL_DIR/data/deploy.json" | cut -d'"' -f4)
    SERVER_NAME=$(grep -o '"name": "[^"]*' "$INSTALL_DIR/data/deploy.json" | head -1 | cut -d'"' -f4)
    PUBLIC_URL=$(grep -o '"publicUrl": "[^"]*' "$INSTALL_DIR/data/deploy.json" | cut -d'"' -f4)

    # Send registration (non-blocking)
    curl -s -X POST "$MAIN_SERVER/api/federation/register" \
        -H "Content-Type: application/json" \
        -d "{\"installId\": \"$INSTALL_ID\", \"name\": \"$SERVER_NAME\", \"url\": \"$PUBLIC_URL\"}" \
        --max-time 10 &>/dev/null &

    echo -e "${GREEN}✓ Registration sent${NC}"
}

# Start the server
start_server() {
    echo -e "${YELLOW}Starting VoiceLink...${NC}"
    cd "$INSTALL_DIR"
    pm2 start ecosystem.config.js
    pm2 save
    echo -e "${GREEN}✓ VoiceLink started${NC}"
}

# Initial doc sync (immediate for quickstart)
initial_doc_sync() {
    echo -e "${YELLOW}Fetching initial documentation...${NC}"
    cd "$INSTALL_DIR"

    # Try to sync basic docs immediately
    node server/tools/docs-sync.js sync 2>/dev/null || {
        echo -e "${YELLOW}○ Doc sync will complete after server starts${NC}"
    }
}

# Print summary
print_summary() {
    PORT=$(grep -o '"port": [0-9]*' "$INSTALL_DIR/data/deploy.json" | grep -o '[0-9]*' || echo "$DEFAULT_PORT")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Installation Complete! 🎉                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Local URL:${NC}     http://localhost:$PORT"
    echo -e "  ${BLUE}Quick Start:${NC}   http://localhost:$PORT/docs/quickstart.html"
    echo -e "  ${BLUE}Admin Docs:${NC}    http://localhost:$PORT/admin/docs/"
    echo -e "  ${BLUE}Install Dir:${NC}   $INSTALL_DIR"
    echo ""
    echo -e "  ${YELLOW}Commands:${NC}"
    echo "    pm2 status          - Check server status"
    echo "    pm2 logs voicelink  - View logs"
    echo "    pm2 restart voicelink - Restart server"
    echo ""
    echo -e "  ${YELLOW}Documentation:${NC}"
    echo "    Docs will sync from main server in ~20 minutes"
    echo "    Or run: node $INSTALL_DIR/server/tools/docs-sync.js sync"
    echo ""
}

# Main installation flow
main() {
    check_node
    check_pm2
    check_ollama
    setup_directories
    download_voicelink
    install_dependencies
    generate_config
    create_quickstart
    create_startup_script
    create_pm2_config
    initial_doc_sync
    start_server
    register_node
    print_summary
}

# Run installer
main "$@"
