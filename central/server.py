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

_REQUIRED_FIELDS = ("node", "timestamp", "rx_delta", "tx_delta")


def _authorized() -> bool:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    token = auth[len("Bearer "):]
    # Constant-time comparison to prevent timing attacks
    return hmac.compare_digest(token, API_SECRET)


@app.post("/report")
def handle_report():
    if not _authorized():
        log.warning("Unauthorized request from %s", request.remote_addr)
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid JSON"}), 400

    missing = [f for f in _REQUIRED_FIELDS if f not in data]
    if missing:
        return jsonify({"error": f"Missing fields: {missing}"}), 400

    try:
        record_report(
            node=str(data["node"]),
            timestamp=int(data["timestamp"]),
            rx_delta=int(data["rx_delta"]),
            tx_delta=int(data["tx_delta"]),
        )
    except (ValueError, TypeError) as exc:
        return jsonify({"error": f"Bad field types: {exc}"}), 400
    except Exception as exc:
        log.error("DB error: %s", exc)
        return jsonify({"error": "Internal server error"}), 500

    log.debug(
        "Recorded report from node=%s rx_delta=%s tx_delta=%s",
        data["node"], data["rx_delta"], data["tx_delta"],
    )
    return jsonify({"status": "ok"})


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


def start_server_thread(host: str = "0.0.0.0", port: int = 8080) -> threading.Thread:
    """Start Flask in a daemon thread so it doesn't block the bot."""
    t = threading.Thread(
        target=lambda: app.run(host=host, port=port, threaded=True, use_reloader=False),
        daemon=True,
        name="http-server",
    )
    t.start()
    log.info("HTTP server started on %s:%d", host, port)
    return t
