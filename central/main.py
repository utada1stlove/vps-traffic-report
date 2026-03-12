"""Central Server entry point — starts HTTP server + Telegram Bot."""
import datetime
import logging
import os

from bot import build_app, daily_report_job
from server import start_server_thread
from store import init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

SERVER_PORT = int(os.environ.get("SERVER_PORT", "8080"))
DAILY_REPORT_TIME = os.environ.get("DAILY_REPORT_TIME", "08:00")  # HH:MM UTC


def _parse_utc_time(s: str) -> datetime.time:
    h, m = map(int, s.split(":"))
    return datetime.time(h, m, 0, tzinfo=datetime.timezone.utc)


def main() -> None:
    log.info("Initializing database…")
    init_db()

    log.info("Starting HTTP server on port %d…", SERVER_PORT)
    start_server_thread(port=SERVER_PORT)

    log.info("Starting Telegram Bot…")
    app = build_app()

    # Schedule daily summary report
    report_time = _parse_utc_time(DAILY_REPORT_TIME)
    app.job_queue.run_daily(
        daily_report_job,
        time=report_time,
        name="daily_report",
    )
    log.info("Daily report scheduled at %s UTC", DAILY_REPORT_TIME)

    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
