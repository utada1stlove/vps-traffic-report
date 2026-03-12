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
                # columns: iface rx_bytes rx_pkts rx_errs rx_drop rx_fifo
                #          rx_frame rx_compressed rx_multicast
                #          tx_bytes tx_pkts ...
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

    Handles counter wrap-around and resets caused by reboots or interface
    resets by treating any decrease in the counter as a full reset.

    On first ever run (no state file) returns (0, 0, ...) to avoid reporting
    the entire kernel counter accumulated since boot as new traffic.
    """
    rx_now, tx_now = read_interface(interface)
    state = _load_state()

    if not state:
        # First run — save baseline, report zero delta
        log.info("First run on %s — saving baseline (rx=%d tx=%d)", interface, rx_now, tx_now)
        _save_state({"rx": rx_now, "tx": tx_now, "updated": time.time()})
        return 0, 0, rx_now, tx_now

    prev_rx = state["rx"]
    prev_tx = state["tx"]

    # Counter reset (reboot / interface down-up) — take current value as delta
    if rx_now < prev_rx or tx_now < prev_tx:
        log.info(
            "Counter reset detected on %s (prev rx=%d tx=%d, now rx=%d tx=%d)",
            interface, prev_rx, prev_tx, rx_now, tx_now,
        )
        rx_delta, tx_delta = rx_now, tx_now
    else:
        rx_delta = rx_now - prev_rx
        tx_delta = tx_now - prev_tx

    _save_state({"rx": rx_now, "tx": tx_now, "updated": time.time()})
    return rx_delta, tx_delta, rx_now, tx_now
