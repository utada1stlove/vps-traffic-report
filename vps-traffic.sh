#!/usr/bin/env bash
# ==============================================================
#  VPS Traffic Monitor — 一键管理脚本
#  用法：
#    wget -qO /tmp/vps.sh https://raw.githubusercontent.com/utada1stlove/vps-traffic-report/refs/heads/main/vps-traffic.sh && bash /tmp/vps.sh
# ==============================================================
set -euo pipefail

# 当 stdin 是管道时（wget ... | bash），重定向到终端以支持交互式输入
# 若 /dev/tty 不可用（无控制终端），则跳过（脚本会在后续 read 时自然报错）
[[ -t 0 ]] || exec </dev/tty 2>/dev/null || true

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" >&2; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
success() { echo -e "${GREEN}[✓]${NC} $*" >&2; }

# ── 常量 ──────────────────────────────────────────────────────
AGENT_DIR="/opt/vps-agent"
CENTRAL_DIR="/opt/vps-central"
AGENT_SVC="vps-agent"
CENTRAL_SVC="vps-central"
AGENT_SVC_FILE="/etc/systemd/system/${AGENT_SVC}.service"
CENTRAL_SVC_FILE="/etc/systemd/system/${CENTRAL_SVC}.service"

# ══════════════════════════════════════════════════════════════
#  写入 Python 源文件
# ══════════════════════════════════════════════════════════════

write_agent_files() {
    local dir="$1"

    cat > "${dir}/traffic_lib.py" << 'PYEOF'
"""Read network traffic from /proc/net/dev and persist state across runs."""
from __future__ import annotations

import json
import logging
import os
import time

log = logging.getLogger(__name__)

STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/vps-agent/state.json")


def read_interface(interface: str) -> tuple[int, int]:
    """Return (rx_bytes, tx_bytes) for *interface* from /proc/net/dev."""
    with open("/proc/net/dev") as f:
        for line in f:
            if interface + ":" in line:
                parts = line.split()
                return int(parts[1]), int(parts[9])
    raise ValueError(f"Interface {interface!r} not found in /proc/net/dev")


def _load_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_state(state: dict) -> None:
    dirname = os.path.dirname(STATE_FILE) or "."
    os.makedirs(dirname, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)


def compute_delta(interface: str) -> tuple[int, int, int, int]:
    """Return (rx_delta, tx_delta, rx_current, tx_current).

    On first ever run returns (0, 0, ...) to avoid reporting the entire
    kernel counter accumulated since boot as new traffic.
    """
    rx_now, tx_now = read_interface(interface)
    state = _load_state()

    if not state:
        log.info("First run on %s — saving baseline (rx=%d tx=%d)", interface, rx_now, tx_now)
        _save_state({"rx": rx_now, "tx": tx_now, "updated": time.time()})
        return 0, 0, rx_now, tx_now

    prev_rx = state["rx"]
    prev_tx = state["tx"]

    if rx_now < prev_rx or tx_now < prev_tx:
        log.info(
            "Counter reset on %s (prev rx=%d tx=%d, now rx=%d tx=%d)",
            interface, prev_rx, prev_tx, rx_now, tx_now,
        )
        rx_delta, tx_delta = rx_now, tx_now
    else:
        rx_delta = rx_now - prev_rx
        tx_delta = tx_now - prev_tx

    _save_state({"rx": rx_now, "tx": tx_now, "updated": time.time()})
    return rx_delta, tx_delta, rx_now, tx_now
PYEOF

    cat > "${dir}/agent.py" << 'PYEOF'
"""VPS Traffic Agent — collect traffic deltas and POST them to Central."""
import logging
import os
import time

import requests

from traffic_lib import compute_delta

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

CENTRAL_URL = os.environ["CENTRAL_URL"].rstrip("/")
NODE_NAME   = os.environ["NODE_NAME"]
API_KEY     = os.environ["API_KEY"]
INTERFACE   = os.environ.get("NETWORK_INTERFACE", "eth0")
INTERVAL    = int(os.environ.get("REPORT_INTERVAL", "60"))
TIMEOUT     = int(os.environ.get("REQUEST_TIMEOUT", "10"))


def _fmt(b: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f}{unit}"
        b /= 1024
    return f"{b:.1f}PB"


def report(rx_delta: int, tx_delta: int, rx_cumulative: int, tx_cumulative: int) -> None:
    payload = {
        "node": NODE_NAME,
        "timestamp": int(time.time()),
        "rx_delta": rx_delta,
        "tx_delta": tx_delta,
        "rx_cumulative": rx_cumulative,
        "tx_cumulative": tx_cumulative,
    }
    resp = requests.post(
        f"{CENTRAL_URL}/report",
        json=payload,
        headers={"Authorization": f"Bearer {API_KEY}"},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    log.info("Reported — rx_delta=%s tx_delta=%s", _fmt(rx_delta), _fmt(tx_delta))


def main() -> None:
    log.info(
        "Agent starting — node=%s interface=%s interval=%ds central=%s",
        NODE_NAME, INTERFACE, INTERVAL, CENTRAL_URL,
    )
    while True:
        try:
            rx_delta, tx_delta, rx_cum, tx_cum = compute_delta(INTERFACE)
            report(rx_delta, tx_delta, rx_cum, tx_cum)
        except Exception as exc:
            log.error("Report failed: %s", exc)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
PYEOF
}

write_central_files() {
    local dir="$1"

    cat > "${dir}/store.py" << 'PYEOF'
"""SQLite storage for Central Server — per-node monthly traffic counters."""
from __future__ import annotations

import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone

DB_PATH           = os.environ.get("DB_PATH", "/var/lib/vps-central/data.db")
OFFLINE_THRESHOLD = int(os.environ.get("OFFLINE_THRESHOLD", "300"))


@contextmanager
def _db():
    dirname = os.path.dirname(DB_PATH) or "."
    os.makedirs(dirname, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with _db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS nodes (
                name        TEXT    PRIMARY KEY,
                last_seen   INTEGER NOT NULL DEFAULT 0,
                rx_month    INTEGER NOT NULL DEFAULT 0,
                tx_month    INTEGER NOT NULL DEFAULT 0,
                month       TEXT    NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS traffic_log (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                node        TEXT    NOT NULL,
                timestamp   INTEGER NOT NULL,
                rx_delta    INTEGER NOT NULL,
                tx_delta    INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_log_node_ts
                ON traffic_log (node, timestamp);
        """)


def record_report(node: str, timestamp: int, rx_delta: int, tx_delta: int) -> None:
    current_month = datetime.now(timezone.utc).strftime("%Y-%m")
    with _db() as conn:
        row = conn.execute(
            "SELECT month FROM nodes WHERE name = ?", (node,)
        ).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO nodes (name, last_seen, rx_month, tx_month, month) VALUES (?,?,?,?,?)",
                (node, timestamp, rx_delta, tx_delta, current_month),
            )
        elif row["month"] != current_month:
            conn.execute(
                "UPDATE nodes SET last_seen=?, rx_month=?, tx_month=?, month=? WHERE name=?",
                (timestamp, rx_delta, tx_delta, current_month, node),
            )
        else:
            conn.execute(
                "UPDATE nodes SET last_seen=?, rx_month=rx_month+?, tx_month=tx_month+? WHERE name=?",
                (timestamp, rx_delta, tx_delta, node),
            )
        conn.execute(
            "INSERT INTO traffic_log (node, timestamp, rx_delta, tx_delta) VALUES (?,?,?,?)",
            (node, timestamp, rx_delta, tx_delta),
        )


def get_node(name: str) -> dict | None:
    with _db() as conn:
        row = conn.execute("SELECT * FROM nodes WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None


def get_all_nodes() -> list[dict]:
    with _db() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM nodes ORDER BY name").fetchall()]


def is_online(last_seen: int) -> bool:
    return (time.time() - last_seen) < OFFLINE_THRESHOLD
PYEOF

    cat > "${dir}/message.py" << 'PYEOF'
"""Format traffic data into Telegram-ready Markdown messages."""
from __future__ import annotations

import time

from store import is_online


def fmt_bytes(b: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.2f} {unit}"
        b /= 1024
    return f"{b:.2f} PB"


def fmt_node(node: dict) -> str:
    name     = node["name"]
    status   = "🟢 Online" if is_online(node["last_seen"]) else "🔴 Offline"
    last_seen = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(node["last_seen"]))
    rx    = fmt_bytes(node["rx_month"])
    tx    = fmt_bytes(node["tx_month"])
    total = fmt_bytes(node["rx_month"] + node["tx_month"])
    month = node["month"] or "—"
    return (
        f"📡 *{name}*\n"
        f"Status: {status}\n"
        f"Month: `{month}`\n"
        f"↓ RX: `{rx}`\n"
        f"↑ TX: `{tx}`\n"
        f"∑ Total: `{total}`\n"
        f"Last seen: `{last_seen}`"
    )


def fmt_all(nodes: list[dict]) -> str:
    if not nodes:
        return "No nodes registered yet."
    lines = ["📊 *All Nodes — Monthly Traffic*\n"]
    for node in nodes:
        icon  = "🟢" if is_online(node["last_seen"]) else "🔴"
        total = fmt_bytes(node["rx_month"] + node["tx_month"])
        rx    = fmt_bytes(node["rx_month"])
        tx    = fmt_bytes(node["tx_month"])
        month = node["month"] or "—"
        lines.append(f"{icon} `{node['name']}` | ↓{rx} ↑{tx} = *{total}* `({month})`")
    online_count = sum(1 for n in nodes if is_online(n["last_seen"]))
    lines.append(f"\n_{online_count}/{len(nodes)} nodes online_")
    return "\n".join(lines)
PYEOF

    cat > "${dir}/server.py" << 'PYEOF'
"""HTTP server — receives POST /report from Agents."""
import hmac
import logging
import os
import threading

from flask import Flask, jsonify, request
from store import record_report

log = logging.getLogger(__name__)
app = Flask(__name__)
API_SECRET = os.environ["API_SECRET"]
_REQUIRED  = ("node", "timestamp", "rx_delta", "tx_delta")


def _authorized() -> bool:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    return hmac.compare_digest(auth[len("Bearer "):], API_SECRET)


@app.post("/report")
def handle_report():
    if not _authorized():
        log.warning("Unauthorized from %s", request.remote_addr)
        return jsonify({"error": "Unauthorized"}), 401
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid JSON"}), 400
    missing = [f for f in _REQUIRED if f not in data]
    if missing:
        return jsonify({"error": f"Missing: {missing}"}), 400
    try:
        record_report(str(data["node"]), int(data["timestamp"]),
                      int(data["rx_delta"]), int(data["tx_delta"]))
    except (ValueError, TypeError) as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        log.error("DB error: %s", e)
        return jsonify({"error": "Internal error"}), 500
    return jsonify({"status": "ok"})


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


def start_server_thread(host: str = "0.0.0.0", port: int = 8080) -> threading.Thread:
    t = threading.Thread(
        target=lambda: app.run(host=host, port=port, threaded=True, use_reloader=False),
        daemon=True, name="http-server",
    )
    t.start()
    log.info("HTTP server started on %s:%d", host, port)
    return t
PYEOF

    cat > "${dir}/bot.py" << 'PYEOF'
"""Telegram Bot — query traffic data via commands."""
import logging
import os

from telegram import Update
from telegram.ext import (
    Application, CallbackContext, CommandHandler,
    ContextTypes, MessageHandler, filters,
)
from message import fmt_all, fmt_node
from store import get_all_nodes, get_node

log     = logging.getLogger(__name__)
BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID   = int(os.environ["TELEGRAM_CHAT_ID"])
_auth     = filters.Chat(chat_id=CHAT_ID)


async def _reply(update: Update, text: str) -> None:
    await update.message.reply_text(text, parse_mode="Markdown")


async def cmd_start(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    await _reply(update,
        "🖥 *VPS Traffic Monitor*\n\n"
        "Commands:\n"
        "/all — all nodes monthly summary\n"
        "/node `<name>` — single node detail\n"
        "/<nodename> — shorthand for /node")


async def cmd_all(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    await _reply(update, fmt_all(get_all_nodes()))


async def cmd_node(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await _reply(update, "Usage: /node `<name>`"); return
    node = get_node(ctx.args[0])
    if node is None:
        await _reply(update, f"Node `{ctx.args[0]}` not found."); return
    await _reply(update, fmt_node(node))


async def cmd_dynamic(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    text = update.message.text or ""
    name = text.lstrip("/").split("@")[0].split()[0]
    node = get_node(name)
    if node is None:
        await _reply(update, f"Node `{name}` not found."); return
    await _reply(update, fmt_node(node))


async def daily_report_job(context: CallbackContext) -> None:
    nodes = get_all_nodes()
    await context.bot.send_message(
        chat_id=CHAT_ID,
        text="📅 *Daily Traffic Report*\n\n" + fmt_all(nodes),
        parse_mode="Markdown",
    )


def build_app() -> Application:
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start, filters=_auth))
    app.add_handler(CommandHandler("all",   cmd_all,   filters=_auth))
    app.add_handler(CommandHandler("node",  cmd_node,  filters=_auth))
    app.add_handler(MessageHandler(filters.COMMAND & _auth, cmd_dynamic))
    return app
PYEOF

    cat > "${dir}/main.py" << 'PYEOF'
"""Central Server entry point."""
import datetime
import logging
import os

from bot import build_app, daily_report_job
from server import start_server_thread
from store import init_db

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

SERVER_PORT       = int(os.environ.get("SERVER_PORT", "8080"))
DAILY_REPORT_TIME = os.environ.get("DAILY_REPORT_TIME", "08:00")


def main() -> None:
    log.info("Initializing database…")
    init_db()
    log.info("Starting HTTP server on port %d…", SERVER_PORT)
    start_server_thread(port=SERVER_PORT)
    log.info("Starting Telegram Bot…")
    app = build_app()
    h, m = map(int, DAILY_REPORT_TIME.split(":"))
    app.job_queue.run_daily(
        daily_report_job,
        time=datetime.time(h, m, 0, tzinfo=datetime.timezone.utc),
        name="daily_report",
    )
    log.info("Daily report scheduled at %s UTC", DAILY_REPORT_TIME)
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYEOF
}

# ══════════════════════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 运行：sudo bash vps-traffic.sh"
        exit 1
    fi
}

ensure_python() {
    local PYTHON=""
    for py in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        if command -v "$py" &>/dev/null; then
            local ver
            ver=$("$py" -c "import sys; v=sys.version_info; print(v.major,v.minor)" 2>/dev/null)
            local maj=${ver%% *} min=${ver##* }
            if [[ "$maj" -ge 3 && "$min" -ge 8 ]]; then
                PYTHON="$py"; break
            fi
        fi
    done

    if [[ -z "$PYTHON" ]]; then
        info "Python 3.8+ 未找到，正在安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y python3 python3-venv python3-pip
        elif command -v dnf &>/dev/null; then
            dnf install -y python3
        elif command -v yum &>/dev/null; then
            yum install -y python3
        else
            error "无法自动安装 Python，请手动安装 Python 3.8+ 后重试"; exit 1
        fi
        PYTHON="python3"
    fi

    # 确保 venv 模块可用（Debian/Ubuntu 单独打包）
    if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
        apt-get install -y python3-venv 2>/dev/null || true
    fi

    echo "$PYTHON"
}

detect_interface() {
    # 返回：用户输入的值，或自动检测值
    local default="$1"
    if ! ip link show "$default" &>/dev/null; then
        local detected
        detected=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
        if [[ -n "$detected" ]]; then
            warn "网卡 '$default' 不存在，自动检测到：$detected"
            read -rp "  使用 '$detected'？[Y/n]: " use_it
            [[ ! "$use_it" =~ ^[Nn]$ ]] && echo "$detected" && return
        fi
    fi
    echo "$default"
}

# ══════════════════════════════════════════════════════════════
#  安装 Agent
# ══════════════════════════════════════════════════════════════

install_agent() {
    check_root
    echo ""
    echo -e "${CYAN}  ── 安装 Agent ──────────────────────────────${NC}"
    echo ""

    # 收集配置
    local CENTRAL_URL NODE_NAME API_KEY INTERFACE INTERVAL

    while true; do
        read -rp "  Central Server 地址（如 http://1.2.3.4:8080）: " CENTRAL_URL
        [[ -n "$CENTRAL_URL" ]] && break
        warn "不能为空"
    done

    while true; do
        read -rp "  节点名称（如 vps1、tokyo-1）: " NODE_NAME
        [[ -n "$NODE_NAME" ]] && break
        warn "不能为空"
    done

    while true; do
        read -rsp "  API Secret（与 Central 一致）: " API_KEY; echo
        [[ -n "$API_KEY" ]] && break
        warn "不能为空"
    done

    read -rp "  网卡名称 [默认 eth0]: " INTERFACE
    INTERFACE="${INTERFACE:-eth0}"
    INTERFACE=$(detect_interface "$INTERFACE")

    read -rp "  上报间隔（秒）[默认 60]: " INTERVAL
    INTERVAL="${INTERVAL:-60}"

    # 安装 Python
    local PYTHON
    PYTHON=$(ensure_python)
    info "Python: $PYTHON ($($PYTHON --version))"

    # 写文件
    info "写入程序文件到 ${AGENT_DIR} ..."
    mkdir -p "$AGENT_DIR"
    write_agent_files "$AGENT_DIR"

    # 写配置
    cat > "${AGENT_DIR}/.env" << EOF
CENTRAL_URL=${CENTRAL_URL}
NODE_NAME=${NODE_NAME}
API_KEY=${API_KEY}
NETWORK_INTERFACE=${INTERFACE}
REPORT_INTERVAL=${INTERVAL}
REQUEST_TIMEOUT=10
STATE_FILE=/var/lib/vps-agent/state.json
EOF
    chmod 600 "${AGENT_DIR}/.env"
    mkdir -p /var/lib/vps-agent

    # 虚拟环境 + 依赖
    info "创建虚拟环境并安装依赖..."
    $PYTHON -m venv "${AGENT_DIR}/venv"
    "${AGENT_DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${AGENT_DIR}/venv/bin/pip" install --quiet requests

    # systemd 服务
    info "注册 systemd 服务..."
    cat > "$AGENT_SVC_FILE" << EOF
[Unit]
Description=VPS Traffic Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${AGENT_DIR}
EnvironmentFile=${AGENT_DIR}/.env
ExecStart=${AGENT_DIR}/venv/bin/python ${AGENT_DIR}/agent.py
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$AGENT_SVC"

    echo ""
    success "Agent 安装完成！"
    echo ""
    echo -e "  节点名称 : ${BOLD}${NODE_NAME}${NC}"
    echo    "  网卡     : ${INTERFACE}"
    echo    "  间隔     : ${INTERVAL}s"
    echo    "  Central  : ${CENTRAL_URL}"
    echo ""
    echo    "  查看状态 : systemctl status ${AGENT_SVC}"
    echo    "  实时日志 : journalctl -u ${AGENT_SVC} -f"
    echo ""
    press_enter
}

# ══════════════════════════════════════════════════════════════
#  安装 Central Server
# ══════════════════════════════════════════════════════════════

install_central() {
    check_root
    echo ""
    echo -e "${CYAN}  ── 安装 Central Server ─────────────────────${NC}"
    echo ""
    echo    "  需要准备："
    echo    "  · Telegram Bot Token（从 @BotFather 获取）"
    echo    "  · Telegram Chat ID（从 @userinfobot 获取）"
    echo    "  · API Secret（自定义随机字符串，Agent 也要填这个）"
    echo ""

    local BOT_TOKEN CHAT_ID API_SECRET PORT DAILY_TIME

    while true; do
        read -rsp "  Telegram Bot Token: " BOT_TOKEN; echo
        [[ -n "$BOT_TOKEN" ]] && break
        warn "不能为空"
    done

    while true; do
        read -rp "  Telegram Chat ID: " CHAT_ID
        [[ -n "$CHAT_ID" ]] && break
        warn "不能为空"
    done

    while true; do
        read -rsp "  API Secret: " API_SECRET; echo
        [[ -n "$API_SECRET" ]] && break
        warn "不能为空"
    done

    read -rp "  HTTP 端口 [默认 8080]: " PORT
    PORT="${PORT:-8080}"

    read -rp "  每日推送时间 UTC HH:MM [默认 08:00]: " DAILY_TIME
    DAILY_TIME="${DAILY_TIME:-08:00}"

    # 安装 Python
    local PYTHON
    PYTHON=$(ensure_python)
    info "Python: $PYTHON ($($PYTHON --version))"

    # 写文件
    info "写入程序文件到 ${CENTRAL_DIR} ..."
    mkdir -p "$CENTRAL_DIR"
    write_central_files "$CENTRAL_DIR"

    # 写配置
    cat > "${CENTRAL_DIR}/.env" << EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
API_SECRET=${API_SECRET}
SERVER_PORT=${PORT}
DAILY_REPORT_TIME=${DAILY_TIME}
OFFLINE_THRESHOLD=300
DB_PATH=/var/lib/vps-central/data.db
EOF
    chmod 600 "${CENTRAL_DIR}/.env"
    mkdir -p /var/lib/vps-central

    # 虚拟环境 + 依赖（python-telegram-bot 较大，提示用户等待）
    info "创建虚拟环境并安装依赖（python-telegram-bot 较大，约需 1 分钟）..."
    $PYTHON -m venv "${CENTRAL_DIR}/venv"
    "${CENTRAL_DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${CENTRAL_DIR}/venv/bin/pip" install --quiet \
        flask \
        'python-telegram-bot[job-queue]'

    # systemd 服务
    info "注册 systemd 服务..."
    cat > "$CENTRAL_SVC_FILE" << EOF
[Unit]
Description=VPS Traffic Central Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CENTRAL_DIR}
EnvironmentFile=${CENTRAL_DIR}/.env
ExecStart=${CENTRAL_DIR}/venv/bin/python ${CENTRAL_DIR}/main.py
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$CENTRAL_SVC"

    # 获取本机 IP 提示用户
    local MY_IP
    MY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

    echo ""
    success "Central Server 安装完成！"
    echo ""
    echo    "  HTTP 端口 : ${PORT}"
    echo    "  日报时间  : ${DAILY_TIME} UTC"
    echo ""
    echo    "  查看状态 : systemctl status ${CENTRAL_SVC}"
    echo    "  实时日志 : journalctl -u ${CENTRAL_SVC} -f"
    echo ""
    echo -e "  ${YELLOW}── 下一步 ──────────────────────────────────────────${NC}"
    echo    "  在每台被监控 VPS 上运行本脚本，选择「安装 Agent」，填入："
    echo -e "    Central 地址 : ${BOLD}http://${MY_IP}:${PORT}${NC}"
    echo    "    API Secret   : （你刚刚输入的那个）"
    echo ""
    press_enter
}

# ══════════════════════════════════════════════════════════════
#  卸载 Agent
# ══════════════════════════════════════════════════════════════

uninstall_agent() {
    check_root
    echo ""
    echo -e "${CYAN}  ── 卸载 Agent ──────────────────────────────${NC}"
    echo ""

    if [[ ! -d "$AGENT_DIR" ]] && ! systemctl is-active --quiet "$AGENT_SVC" 2>/dev/null; then
        warn "未检测到 Agent 安装，无需卸载。"
        press_enter; return
    fi

    warn "将停止并移除 Agent 服务和程序文件。"
    read -rp "  同时删除流量基准数据（/var/lib/vps-agent）？[y/N]: " DEL_DATA

    # 停止 + 禁用服务
    if systemctl is-active --quiet "$AGENT_SVC" 2>/dev/null; then
        info "停止服务..."; systemctl stop "$AGENT_SVC"
    fi
    if systemctl is-enabled --quiet "$AGENT_SVC" 2>/dev/null; then
        info "禁用服务..."; systemctl disable "$AGENT_SVC"
    fi
    if [[ -f "$AGENT_SVC_FILE" ]]; then
        rm -f "$AGENT_SVC_FILE"; systemctl daemon-reload
    fi

    [[ -d "$AGENT_DIR" ]] && { info "删除 ${AGENT_DIR} ..."; rm -rf "$AGENT_DIR"; }

    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        [[ -d "/var/lib/vps-agent" ]] && rm -rf "/var/lib/vps-agent"
        info "基准数据已删除。"
    fi

    success "Agent 已卸载。"
    echo ""
    press_enter
}

# ══════════════════════════════════════════════════════════════
#  卸载 Central Server
# ══════════════════════════════════════════════════════════════

uninstall_central() {
    check_root
    echo ""
    echo -e "${CYAN}  ── 卸载 Central Server ─────────────────────${NC}"
    echo ""

    if [[ ! -d "$CENTRAL_DIR" ]] && ! systemctl is-active --quiet "$CENTRAL_SVC" 2>/dev/null; then
        warn "未检测到 Central 安装，无需卸载。"
        press_enter; return
    fi

    warn "将停止并移除 Central 服务和程序文件。"
    read -rp "  同时删除流量数据库（/var/lib/vps-central）？[y/N]: " DEL_DATA

    if systemctl is-active --quiet "$CENTRAL_SVC" 2>/dev/null; then
        info "停止服务..."; systemctl stop "$CENTRAL_SVC"
    fi
    if systemctl is-enabled --quiet "$CENTRAL_SVC" 2>/dev/null; then
        info "禁用服务..."; systemctl disable "$CENTRAL_SVC"
    fi
    if [[ -f "$CENTRAL_SVC_FILE" ]]; then
        rm -f "$CENTRAL_SVC_FILE"; systemctl daemon-reload
    fi

    [[ -d "$CENTRAL_DIR" ]] && { info "删除 ${CENTRAL_DIR} ..."; rm -rf "$CENTRAL_DIR"; }

    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        [[ -d "/var/lib/vps-central" ]] && rm -rf "/var/lib/vps-central"
        info "数据库已删除。"
    fi

    success "Central Server 已卸载。"
    echo ""
    press_enter
}

# ══════════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════════

press_enter() {
    read -rp "  按 Enter 返回主菜单..." _dummy
}

show_status() {
    local agent_status central_status
    if systemctl is-active --quiet "$AGENT_SVC" 2>/dev/null; then
        agent_status="${GREEN}运行中${NC}"
    elif [[ -d "$AGENT_DIR" ]]; then
        agent_status="${YELLOW}已安装/未运行${NC}"
    else
        agent_status="${RED}未安装${NC}"
    fi

    if systemctl is-active --quiet "$CENTRAL_SVC" 2>/dev/null; then
        central_status="${GREEN}运行中${NC}"
    elif [[ -d "$CENTRAL_DIR" ]]; then
        central_status="${YELLOW}已安装/未运行${NC}"
    else
        central_status="${RED}未安装${NC}"
    fi

    echo -e "  Agent         : $agent_status"
    echo -e "  Central Server: $central_status"
}

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}  ║       VPS 流量监控 — 管理脚本            ║${NC}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════╝${NC}"
        echo ""
        show_status
        echo ""
        echo    "  ────────────────────────────────────────────"
        echo    "  1) 安装 Agent        （被监控 VPS 上运行）"
        echo    "  2) 安装 Central Server（接收数据 + Telegram Bot）"
        echo    "  3) 卸载 Agent"
        echo    "  4) 卸载 Central Server"
        echo    "  ────────────────────────────────────────────"
        echo    "  0) 退出"
        echo ""
        read -rp "  请选择 [0-4]: " choice

        case "$choice" in
            1) install_agent   ;;
            2) install_central ;;
            3) uninstall_agent ;;
            4) uninstall_central ;;
            0) echo ""; echo "  再见。"; echo ""; exit 0 ;;
            *) warn "无效选项：$choice" ; sleep 1 ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────
main_menu
