#!/usr/bin/env python3
import os, subprocess, logging
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("pi-bot")

TOKEN = os.environ["BOT_TOKEN"]
ALLOWED_IDS = {int(x) for x in os.environ.get("ALLOWED_IDS", "").split(",") if x.strip()}
# Webhook mode is used when WEBHOOK_URL is set; otherwise the bot long-polls.
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "").strip()
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "").strip() or None
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8081"))

def authorized(update: Update) -> bool:
    u = update.effective_user
    ok = u is not None and u.id in ALLOWED_IDS
    if not ok:
        log.warning("Rejected user %s (%s)", u.id if u else "?", u.username if u else "?")
    return ok

def run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return (r.stdout or r.stderr).strip()
    except Exception as e:
        return f"error: {e}"

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if uid in ALLOWED_IDS:
        await update.message.reply_text(
            "Commands:\n/status - uptime, temp, Apache\n/reboot - restart the Pi\n/shutdown - power off the Pi")
    else:
        await update.message.reply_text(f"Your user ID is {uid}. Not authorized.")

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return
    disk = run(["df", "-h", "--output=pcent", "/"]).splitlines()[-1].strip()
    await update.message.reply_text(
        f"Uptime: {run(['uptime', '-p'])}\nTemp: {run(['vcgencmd', 'measure_temp'])}\n"
        f"Apache: {run(['systemctl', 'is-active', 'apache2'])}\nDisk used: {disk}")

async def confirm(update: Update, action: str):
    if not authorized(update):
        return
    kb = InlineKeyboardMarkup([[InlineKeyboardButton(f"Yes, {action}", callback_data=action),
                                InlineKeyboardButton("Cancel", callback_data="cancel")]])
    await update.message.reply_text(f"Really {action} the Pi?", reply_markup=kb)

async def shutdown_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await confirm(update, "shutdown")

async def reboot_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await confirm(update, "reboot")

async def button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not authorized(update):
        return
    if q.data == "shutdown":
        await q.edit_message_text("Shutting down... bye!")
        log.info("Shutdown by %s", update.effective_user.id)
        subprocess.Popen(["sudo", "/sbin/shutdown", "-h", "+0"])
    elif q.data == "reboot":
        await q.edit_message_text("Rebooting... back in a minute.")
        log.info("Reboot by %s", update.effective_user.id)
        subprocess.Popen(["sudo", "/sbin/shutdown", "-r", "+0"])
    else:
        await q.edit_message_text("Cancelled.")

def main():
    if not ALLOWED_IDS:
        log.warning("ALLOWED_IDS is empty: send /start to the bot to learn your ID.")
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("shutdown", shutdown_cmd))
    app.add_handler(CommandHandler("reboot", reboot_cmd))
    app.add_handler(CallbackQueryHandler(button))
    if WEBHOOK_URL:
        from urllib.parse import urlparse
        path = urlparse(WEBHOOK_URL).path.lstrip("/")
        log.info("Webhook mode on 127.0.0.1:%s/%s", LISTEN_PORT, path)
        # Listens only on localhost; cloudflared forwards public traffic here.
        # Requests without Telegram's secret header are rejected.
        app.run_webhook(listen="127.0.0.1", port=LISTEN_PORT, url_path=path,
                        webhook_url=WEBHOOK_URL, secret_token=WEBHOOK_SECRET)
    else:
        log.info("Polling mode")
        app.run_polling(timeout=50)

if __name__ == "__main__":
    main()
