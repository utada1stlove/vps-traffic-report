#!/usr/bin/env bash
# ============================================================
#  VPS Traffic Central Server — Installer (systemd + venv)
#  Run as root: sudo bash install.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/vps-central"
SERVICE_NAME="vps-central"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Please run as root:  sudo bash install.sh"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  VPS Traffic Central — Installer     ║"
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

if ! $PYTHON -m venv --help &>/dev/null 2>&1; then
    apt-get install -y python3-venv 2>/dev/null || true
fi

# ── Interactive config ────────────────────────────────────────────────────────
echo ""
echo "  Please enter configuration values."
echo ""

while true; do
    read -rsp "  Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    echo
    [[ -n "$TELEGRAM_BOT_TOKEN" ]] && break
    warn "Bot token is required."
done

while true; do
    read -rp "  Telegram Chat ID (your user ID or group ID): " TELEGRAM_CHAT_ID
    [[ -n "$TELEGRAM_CHAT_ID" ]] && break
    warn "Chat ID is required."
done

while true; do
    read -rsp "  API Secret (all Agents must use this same secret): " API_SECRET
    echo
    [[ -n "$API_SECRET" ]] && break
    warn "API Secret is required."
done

read -rp "  Server port [default: 8080]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-8080}"

read -rp "  Daily report time UTC HH:MM [default: 08:00]: " DAILY_REPORT_TIME
DAILY_REPORT_TIME="${DAILY_REPORT_TIME:-08:00}"

# ── Install files ─────────────────────────────────────────────────────────────
info "Installing files to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/store.py" \
   "$SCRIPT_DIR/server.py" \
   "$SCRIPT_DIR/bot.py" \
   "$SCRIPT_DIR/message.py" \
   "$SCRIPT_DIR/main.py" \
   "$INSTALL_DIR/"

# Write env file (chmod 600 — contains secrets)
cat > "$INSTALL_DIR/.env" <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
API_SECRET=${API_SECRET}
SERVER_PORT=${SERVER_PORT}
DAILY_REPORT_TIME=${DAILY_REPORT_TIME}
OFFLINE_THRESHOLD=300
DB_PATH=/var/lib/vps-central/data.db
EOF
chmod 600 "$INSTALL_DIR/.env"

# Data directory
mkdir -p /var/lib/vps-central

# ── Virtualenv + dependencies ─────────────────────────────────────────────────
info "Creating virtualenv and installing dependencies..."
info "(This may take a minute — python-telegram-bot is a large package)"
$PYTHON -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet \
    flask \
    'python-telegram-bot[job-queue]'

# ── Systemd service ───────────────────────────────────────────────────────────
info "Installing systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Traffic Central Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/main.py
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# Detect outbound IP for display
MY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

echo ""
echo "  ╔═══════════════════════════════════════════════════════╗"
info "  Central Server installed and running!"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  HTTP port : $SERVER_PORT"
echo "  Daily rpt : $DAILY_REPORT_TIME UTC"
echo ""
echo "  Status : systemctl status $SERVICE_NAME"
echo "  Logs   : journalctl -u $SERVICE_NAME -f"
echo "  Stop   : systemctl stop $SERVICE_NAME"
echo ""
echo "  ── Next step ────────────────────────────────────────────"
echo "  On each Agent VPS, run agent/install.sh with:"
echo "    Central URL : http://${MY_IP}:${SERVER_PORT}"
echo "    API Secret  : (the secret you just entered)"
echo ""
