"""SQLite storage for Central Server — per-node monthly traffic counters."""
from __future__ import annotations

import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone

DB_PATH = os.environ.get("DB_PATH", "/var/lib/vps-central/data.db")
OFFLINE_THRESHOLD = int(os.environ.get("OFFLINE_THRESHOLD", "300"))  # seconds


@contextmanager
def _db():
    """Open a connection, commit on success, rollback on error, always close."""
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


def record_report(
    node: str,
    timestamp: int,
    rx_delta: int,
    tx_delta: int,
) -> None:
    current_month = datetime.now(timezone.utc).strftime("%Y-%m")

    with _db() as conn:
        row = conn.execute(
            "SELECT month, rx_month, tx_month FROM nodes WHERE name = ?",
            (node,),
        ).fetchone()

        if row is None:
            conn.execute(
                """INSERT INTO nodes (name, last_seen, rx_month, tx_month, month)
                   VALUES (?, ?, ?, ?, ?)""",
                (node, timestamp, rx_delta, tx_delta, current_month),
            )
        elif row["month"] != current_month:
            # New month — reset monthly counters
            conn.execute(
                """UPDATE nodes
                   SET last_seen=?, rx_month=?, tx_month=?, month=?
                   WHERE name=?""",
                (timestamp, rx_delta, tx_delta, current_month, node),
            )
        else:
            conn.execute(
                """UPDATE nodes
                   SET last_seen=?, rx_month=rx_month+?, tx_month=tx_month+?
                   WHERE name=?""",
                (timestamp, rx_delta, tx_delta, node),
            )

        conn.execute(
            """INSERT INTO traffic_log (node, timestamp, rx_delta, tx_delta)
               VALUES (?, ?, ?, ?)""",
            (node, timestamp, rx_delta, tx_delta),
        )


def get_node(name: str) -> dict | None:
    with _db() as conn:
        row = conn.execute(
            "SELECT * FROM nodes WHERE name = ?", (name,)
        ).fetchone()
        return dict(row) if row else None


def get_all_nodes() -> list[dict]:
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM nodes ORDER BY name"
        ).fetchall()
        return [dict(r) for r in rows]


def is_online(last_seen: int) -> bool:
    return (time.time() - last_seen) < OFFLINE_THRESHOLD
