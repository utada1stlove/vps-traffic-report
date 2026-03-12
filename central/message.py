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
    name = node["name"]
    online = is_online(node["last_seen"])
    status = "🟢 Online" if online else "🔴 Offline"
    last_seen = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(node["last_seen"]))
    rx = fmt_bytes(node["rx_month"])
    tx = fmt_bytes(node["tx_month"])
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
        icon = "🟢" if is_online(node["last_seen"]) else "🔴"
        total = fmt_bytes(node["rx_month"] + node["tx_month"])
        rx = fmt_bytes(node["rx_month"])
        tx = fmt_bytes(node["tx_month"])
        month = node["month"] or "—"
        lines.append(
            f"{icon} `{node['name']}` | ↓{rx} ↑{tx} = *{total}* `({month})`"
        )

    online_count = sum(1 for n in nodes if is_online(n["last_seen"]))
    lines.append(f"\n_{online_count}/{len(nodes)} nodes online_")
    return "\n".join(lines)
