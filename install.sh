#!/usr/bin/env bash
# Installs a Telegram bot that can report status, reboot, or shut down this Pi.
# Run from the repo folder as your normal user (NOT with sudo):   bash install.sh
# Re-run any time to update the bot after a `git pull`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/pi_bot.py" ]]; then
  echo "pi_bot.py not found next to install.sh. Run this from the cloned repo."; exit 1
fi

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (e.g. pi), not root. It will use sudo when needed."
  exit 1
fi

BOT_USER="$USER"
BOT_DIR="$HOME/tgbot"
ENV_FILE="/etc/tgbot.env"
SUDOERS_FILE="/etc/sudoers.d/tgbot"
SERVICE_FILE="/etc/systemd/system/tgbot.service"

echo "== Telegram Pi control bot installer =="
echo "User: $BOT_USER   Install dir: $BOT_DIR"
echo

# --- Ask for secrets -------------------------------------------------------
read -rsp "Paste your bot token from @BotFather (input hidden): " BOT_TOKEN; echo
if [[ ! "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "That doesn't look like a bot token (expected 123456:ABC...)."; exit 1
fi
echo "Your Telegram user ID (get it from @userinfobot, or leave empty and"
read -rp "send /start to your bot later to learn it): " ALLOWED_IDS
ALLOWED_IDS="${ALLOWED_IDS// /}"

echo
echo "Webhook mode (optional): enter the public HTTPS hostname your Cloudflare"
echo "tunnel will route to this bot, e.g. bot.example.com"
read -rp "Leave empty to use polling instead: " WEBHOOK_HOST
WEBHOOK_HOST="${WEBHOOK_HOST#https://}"; WEBHOOK_HOST="${WEBHOOK_HOST%%/*}"
LISTEN_PORT=8081
WEBHOOK_URL=""
WEBHOOK_SECRET=""
if [[ -n "$WEBHOOK_HOST" ]]; then
  # Random, hard-to-guess path plus a secret header that Telegram sends back.
  WEBHOOK_PATH="tg-$(python3 -c 'import secrets;print(secrets.token_hex(12))')"
  WEBHOOK_URL="https://$WEBHOOK_HOST/$WEBHOOK_PATH"
  WEBHOOK_SECRET="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
fi

# --- Packages & venv -------------------------------------------------------
echo "-> Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq python3-venv python3-pip >/dev/null

mkdir -p "$BOT_DIR"
python3 -m venv "$BOT_DIR/venv"
"$BOT_DIR/venv/bin/pip" install -q --upgrade pip
"$BOT_DIR/venv/bin/pip" install -q "python-telegram-bot[webhooks]>=21,<23"

# --- Bot script ------------------------------------------------------------
echo "-> Installing bot script..."
install -m 755 "$SCRIPT_DIR/pi_bot.py" "$BOT_DIR/pi_bot.py"

# --- Secrets file ----------------------------------------------------------
echo "-> Saving token to $ENV_FILE (readable by root only)..."
printf 'BOT_TOKEN=%s\nALLOWED_IDS=%s\nWEBHOOK_URL=%s\nWEBHOOK_SECRET=%s\nLISTEN_PORT=%s\n' \
  "$BOT_TOKEN" "$ALLOWED_IDS" "$WEBHOOK_URL" "$WEBHOOK_SECRET" "$LISTEN_PORT" \
  | sudo tee "$ENV_FILE" >/dev/null
sudo chmod 600 "$ENV_FILE"
sudo chown root:root "$ENV_FILE"

# --- Sudoers rule (validated before install) -------------------------------
echo "-> Allowing $BOT_USER to run shutdown without a password..."
TMP_SUDO="$(mktemp)"
echo "$BOT_USER ALL=(root) NOPASSWD: /sbin/shutdown" > "$TMP_SUDO"
if sudo visudo -cf "$TMP_SUDO" >/dev/null; then
  sudo install -m 440 -o root -g root "$TMP_SUDO" "$SUDOERS_FILE"
else
  echo "Sudoers check failed; not installing rule."; rm -f "$TMP_SUDO"; exit 1
fi
rm -f "$TMP_SUDO"

# --- systemd service -------------------------------------------------------
echo "-> Creating systemd service..."
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Telegram Pi control bot
After=network-online.target
Wants=network-online.target

[Service]
User=$BOT_USER
WorkingDirectory=$BOT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/pi_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tgbot >/dev/null
sleep 3

echo
if systemctl is-active --quiet tgbot; then
  echo "✅ Bot is running. Open your bot in Telegram and send /start."
else
  echo "⚠️  Service didn't start. Check: journalctl -u tgbot -n 50"
fi
if [[ -z "$ALLOWED_IDS" ]]; then
  echo
  echo "No user ID set yet. Send /start to the bot to see your ID, then run:"
  echo "  sudo nano $ENV_FILE        # put your ID after ALLOWED_IDS="
  echo "  sudo systemctl restart tgbot"
fi
if [[ -n "$WEBHOOK_HOST" ]]; then
  echo
  echo "Webhook mode: point your Cloudflare tunnel hostname $WEBHOOK_HOST at"
  echo "  http://localhost:$LISTEN_PORT"
  echo "Until the tunnel route exists, Telegram can't deliver messages."
  echo "Check delivery with:  sudo grep BOT_TOKEN $ENV_FILE  then open"
  echo "  https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
fi
echo "Logs: journalctl -u tgbot -f"
