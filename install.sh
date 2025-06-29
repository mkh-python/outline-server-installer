#!/bin/bash

set -e

CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${CYAN}🔧 به‌روزرسانی سیستم و نصب ابزارهای لازم...${RESET}"
apt update && apt upgrade -y
apt install -y curl wget sudo unzip python3 python3-venv python3-pip jq docker.io

echo -e "${CYAN}🐳 راه‌اندازی Docker...${RESET}"
systemctl enable docker
systemctl start docker

echo -e "${CYAN}🌐 نصب Cloudflared و ورود به حساب Cloudflare...${RESET}"
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O cloudflared.deb
dpkg -i cloudflared.deb

read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " MAIN_DOMAIN
SUB_DOMAIN="outlinemkh.$MAIN_DOMAIN"

echo -e "${CYAN}🌐 ورود به Cloudflare برای ایجاد Tunnel...${RESET}"
cloudflared login

TUN_NAME="outline-tunnel"
EXISTING_TUNNEL=$(cloudflared tunnel list --output json | jq -r ".[] | select(.name==\"$TUN_NAME\") | .id")

if [ -n "$EXISTING_TUNNEL" ]; then
  echo "⚠️ تونل با نام $TUN_NAME وجود دارد. حذف در حال انجام..."
  cloudflared tunnel delete "$TUN_NAME"
  rm -f /root/.cloudflared/*.json
fi

TUN_ID=$(cloudflared tunnel create "$TUN_NAME" | grep "Tunnel credentials written" | awk '{print $4}')
TUN_ID_FILENAME=$(basename "$TUN_ID")

echo -e "${CYAN}📄 تنظیم فایل config.yml برای Cloudflare Tunnel...${RESET}"
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUN_NAME
credentials-file: /root/.cloudflared/$TUN_ID_FILENAME
ingress:
  - hostname: $SUB_DOMAIN
    service: https://localhost
  - service: http_status:404
EOF

cloudflared tunnel route dns "$TUN_NAME" "$SUB_DOMAIN"
systemctl enable cloudflared
systemctl restart cloudflared

echo -e "${CYAN}🛠 نصب Outline Server...${RESET}"
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

OUTLINE_ACCESS=$(find /root -type f -name "access.txt" | head -n 1)
CERT_SHA256=$(grep "certSha256:" $OUTLINE_ACCESS | cut -d':' -f2 | tr -d ' ')
API_PORT=$(grep "apiUrl:" $OUTLINE_ACCESS | cut -d':' -f4)
OUTLINE_API_URL="https://$SUB_DOMAIN:$API_PORT"

echo "✅ Outline نصب شد. آدرس: $OUTLINE_API_URL"

# ──────────────────────────────────────────────
# ⚙️ نصب و پیکربندی ربات Telegram
# ──────────────────────────────────────────────
read -p "توکن ربات تلگرام را وارد کنید: " BOT_TOKEN

ADMIN_IDS=()
while true; do
  read -p "آیدی عددی مدیر را وارد کنید (یا n برای پایان): " ADMIN_ID
  [[ "$ADMIN_ID" == "n" ]] && break
  ADMIN_IDS+=("$ADMIN_ID")
done

read -p "📥 لینک کانال بکاپ (عمومی یا خصوصی): " BACKUP_CHANNEL
if [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+ ]]; then
  read -p "🔢 آیدی عددی کانال خصوصی (مثل -1001234567890): " BACKUP_CHANNEL_ID
else
  BACKUP_CHANNEL_ID=null
fi

mkdir -p /opt/outline_bot
cd /opt/outline_bot
python3 -m venv outline_env
source outline_env/bin/activate
pip install --upgrade pip
pip install requests python-telegram-bot pytz "python-telegram-bot[job-queue]"

wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/outline_bot.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/delete_user.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/users_data.json

cat > /opt/outline_bot/.config.json <<EOF
{
  "OUTLINE_API_URL": "$OUTLINE_API_URL",
  "CERT_SHA256": "$CERT_SHA256",
  "BOT_TOKEN": "$BOT_TOKEN",
  "ADMIN_IDS": [$(IFS=, ; echo "${ADMIN_IDS[*]}")],
  "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
  "BACKUP_CHANNEL_ID": "$BACKUP_CHANNEL_ID"
}
EOF

mkdir -p /opt/outline_bot/logs
touch /opt/outline_bot/service.log

# کرون‌جاب حذف کاربر منقضی‌شده
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/delete_user.py") | crontab -

cat > /etc/systemd/system/outline_bot.service <<EOF
[Unit]
Description=Outline Bot Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/outline_bot
ExecStart=/opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/outline_bot.py
Restart=always
StandardOutput=append:/opt/outline_bot/service.log
StandardError=append:/opt/outline_bot/service.log

[Install]
WantedBy=multi-user.target
EOF

timedatectl set-timezone Asia/Tehran
systemctl daemon-reload
systemctl enable outline_bot.service
systemctl start outline_bot.service

# پیام نهایی
curl -s -X POST https://api.telegram.org/bot$BOT_TOKEN/sendMessage \
-d "chat_id=${ADMIN_IDS[0]}" \
-d "text=✅ سرور و ربات نصب شدند.\n\n🌐 آدرس: $OUTLINE_API_URL\n🔐 کد TLS: $CERT_SHA256\n\n🛠 از منیجر برای اتصال استفاده کنید."

echo -e "${CYAN}✅ نصب کامل شد. سرور روی $SUB_DOMAIN فعال است و ترافیک از Cloudflare Tunnel عبور می‌کند.${RESET}"
