#!/usr/bin/env bash
# ============================================================
#  VPS Traffic Agent — Uninstaller
#  Run as root: sudo bash uninstall.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/vps-agent"
SERVICE_NAME="vps-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Please run as root:  sudo bash uninstall.sh"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   VPS Traffic Agent — Uninstaller    ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
warn "This will stop and remove the VPS Traffic Agent."
read -rp "  Also delete state data (/var/lib/vps-agent)? [y/N]: " REMOVE_DATA

# Stop service
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Stopping service..."
    systemctl stop "$SERVICE_NAME"
fi

# Disable service
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Disabling service..."
    systemctl disable "$SERVICE_NAME"
fi

# Remove service file
if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
fi

# Remove install directory
if [[ -d "$INSTALL_DIR" ]]; then
    info "Removing $INSTALL_DIR ..."
    rm -rf "$INSTALL_DIR"
fi

# Optionally remove state data
if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then
    if [[ -d "/var/lib/vps-agent" ]]; then
        info "Removing state data..."
        rm -rf "/var/lib/vps-agent"
    fi
fi

info "Agent uninstalled."
echo ""
