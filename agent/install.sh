#!/usr/bin/env bash
# ============================================================
#  VPS Traffic Agent — Installer (systemd + venv, no Docker)
#  Run as root: sudo bash install.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/vps-agent"
SERVICE_NAME="vps-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Please run as root:  sudo bash install.sh"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   VPS Traffic Agent — Installer      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Python 3.8+ ───────────────────────────────────────────────────────────────
PYTHON=""
for py in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$py" &>/dev/null; then
        ver=$("$py" -c "import sys; v=sys.version_info; print(v.major,v.minor)" 2>/dev/null)
        maj=${ver%% *}; min=${ver##* }
        if [[ "$maj" -ge 3 && "$min" -ge 8 ]]; then
            PYTHON="$py"; break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    info "Python 3.8+ not found — installing..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y python3 python3-venv python3-pip
    elif command -v dnf &>/dev/null; then
        dnf install -y python3
    elif command -v yum &>/dev/null; then
        yum install -y python3
    else
        error "Cannot auto-install Python. Please install Python 3.8+ and re-run."
    fi
    PYTHON="python3"
fi
info "Python: $PYTHON ($($PYTHON --version))"

# Ensure venv module is available (Debian/Ubuntu split it out)
if ! $PYTHON -m venv --help &>/dev/null 2>&1; then
    apt-get install -y python3-venv 2>/dev/null || true
fi

# ── Interactive config ────────────────────────────────────────────────────────
echo ""
echo "  Please enter configuration values."
echo ""

while true; do
    read -rp "  Central Server URL (e.g. http://1.2.3.4:8080): " CENTRAL_URL
    [[ -n "$CENTRAL_URL" ]] && break
    warn "Central URL is required."
done

while true; do
    read -rp "  Node name for this VPS (e.g. vps1, tokyo-1): " NODE_NAME
    [[ -n "$NODE_NAME" ]] && break
    warn "Node name is required."
done

while true; do
    read -rsp "  API Secret (must match Central's API_SECRET): " API_KEY
    echo
    [[ -n "$API_KEY" ]] && break
    warn "API Secret is required."
done

read -rp "  Network interface [default: eth0]: " INTERFACE
INTERFACE="${INTERFACE:-eth0}"

# Auto-detect if specified interface doesn't exist
if ! ip link show "$INTERFACE" &>/dev/null; then
    DETECTED=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "$DETECTED" ]]; then
        warn "Interface '$INTERFACE' not found. Auto-detected: $DETECTED"
        read -rp "  Use '$DETECTED' instead? [Y/n]: " USE_DETECTED
        [[ ! "$USE_DETECTED" =~ ^[Nn]$ ]] && INTERFACE="$DETECTED"
    fi
fi

read -rp "  Report interval in seconds [default: 60]: " INTERVAL
INTERVAL="${INTERVAL:-60}"

# ── Install files ─────────────────────────────────────────────────────────────
info "Installing files to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/agent.py" "$SCRIPT_DIR/traffic_lib.py" "$INSTALL_DIR/"

# Write env file (chmod 600 — contains secret)
cat > "$INSTALL_DIR/.env" <<EOF
CENTRAL_URL=${CENTRAL_URL}
NODE_NAME=${NODE_NAME}
API_KEY=${API_KEY}
NETWORK_INTERFACE=${INTERFACE}
REPORT_INTERVAL=${INTERVAL}
REQUEST_TIMEOUT=10
STATE_FILE=/var/lib/vps-agent/state.json
EOF
chmod 600 "$INSTALL_DIR/.env"

# State directory
mkdir -p /var/lib/vps-agent

# ── Virtualenv + dependencies ─────────────────────────────────────────────────
info "Creating virtualenv and installing dependencies..."
$PYTHON -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet requests

# ── Systemd service ───────────────────────────────────────────────────────────
info "Installing systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Traffic Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/agent.py
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
info "  Agent installed and running!"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Node name : $NODE_NAME"
echo "  Interface : $INTERFACE"
echo "  Interval  : ${INTERVAL}s"
echo "  Central   : $CENTRAL_URL"
echo ""
echo "  Status : systemctl status $SERVICE_NAME"
echo "  Logs   : journalctl -u $SERVICE_NAME -f"
echo "  Stop   : systemctl stop $SERVICE_NAME"
echo ""
