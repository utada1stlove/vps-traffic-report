"""Telegram Bot — query traffic data via commands."""
import logging
import os

from telegram import Update
from telegram.ext import (
    Application,
    CallbackContext,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from message import fmt_all, fmt_node
from store import get_all_nodes, get_node

log = logging.getLogger(__name__)

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID = int(os.environ["TELEGRAM_CHAT_ID"])

# Only process messages from the authorized chat
_auth_filter = filters.Chat(chat_id=CHAT_ID)


# ── helpers ───────────────────────────────────────────────────────────────────

async def _reply(update: Update, text: str) -> None:
    await update.message.reply_text(text, parse_mode="Markdown")


# ── command handlers ──────────────────────────────────────────────────────────

async def cmd_start(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    await _reply(
        update,
        "🖥 *VPS Traffic Monitor*\n\n"
        "Commands:\n"
        "/all — all nodes monthly summary\n"
        "/node `<name>` — single node detail\n"
        "/<nodename> — shorthand for /node",
    )


async def cmd_all(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    nodes = get_all_nodes()
    await _reply(update, fmt_all(nodes))


async def cmd_node(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await _reply(update, "Usage: /node `<name>`")
        return
    name = ctx.args[0]
    node = get_node(name)
    if node is None:
        await _reply(update, f"Node `{name}` not found.")
        return
    await _reply(update, fmt_node(node))


async def cmd_dynamic(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle /<nodename> — dynamically resolve node names."""
    text = update.message.text or ""
    # Strip leading slash, handle /name@botname, ignore arguments
    node_name = text.lstrip("/").split("@")[0].split()[0]
    node = get_node(node_name)
    if node is None:
        await _reply(update, f"Node `{node_name}` not found.")
        return
    await _reply(update, fmt_node(node))


# ── job queue callback ────────────────────────────────────────────────────────

async def daily_report_job(context: CallbackContext) -> None:
    """Scheduled daily summary pushed to TELEGRAM_CHAT_ID."""
    nodes = get_all_nodes()
    text = "📅 *Daily Traffic Report*\n\n" + fmt_all(nodes)
    await context.bot.send_message(chat_id=CHAT_ID, text=text, parse_mode="Markdown")


# ── application factory ───────────────────────────────────────────────────────

def build_app() -> Application:
    application = Application.builder().token(BOT_TOKEN).build()

    # Specific commands first (highest priority)
    application.add_handler(CommandHandler("start", cmd_start, filters=_auth_filter))
    application.add_handler(CommandHandler("all", cmd_all, filters=_auth_filter))
    application.add_handler(CommandHandler("node", cmd_node, filters=_auth_filter))

    # Catch-all for unknown commands — try to look up as node name
    application.add_handler(
        MessageHandler(filters.COMMAND & _auth_filter, cmd_dynamic)
    )

    return application
