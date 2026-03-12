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
NODE_NAME = os.environ["NODE_NAME"]
API_KEY = os.environ["API_KEY"]
INTERFACE = os.environ.get("NETWORK_INTERFACE", "eth0")
INTERVAL = int(os.environ.get("REPORT_INTERVAL", "60"))
TIMEOUT = int(os.environ.get("REQUEST_TIMEOUT", "10"))


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
    log.info(
        "Reported to %s — rx_delta=%s tx_delta=%s",
        CENTRAL_URL,
        _fmt(rx_delta),
        _fmt(tx_delta),
    )


def _fmt(b: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f}{unit}"
        b /= 1024
    return f"{b:.1f}PB"


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
