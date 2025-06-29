#!/bin/bash

# نصب وابستگی‌ها
apt update && apt upgrade -y
apt install -y python3 python3-pip python3-venv curl jq docker.io cloudflared

# شروع داکر
systemctl enable --now docker

# ساخت محیط مجازی
mkdir -p /opt/outline_bot/outline_env
python3 -m venv /opt/outline_bot/outline_env
source /opt/outline_bot/outline_env/bin/activate

# دانلود فایل‌های ربات
mkdir -p /opt/outline_bot
cd /opt/outline_bot

wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/outline_bot.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/delete_user.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/users_data.json
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/update.sh
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/README.md
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/version.txt
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/install.sh

chmod +x *.py
chmod +x update.sh

# نصب Outline Server
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# بررسی فایل access.txt
ACCESS_FILE="/opt/outline/access.txt"
if [ ! -f "$ACCESS_FILE" ]; then
    echo "فایل access.txt پیدا نشد."
    exit 1
fi

# دریافت اطلاعات API
API_URL=$(grep "apiUrl:" $ACCESS_FILE | awk '{print $2}' | tr -d '"')
CERT_SHA256=$(grep "certSha256:" $ACCESS_FILE | awk '{print $2}' | tr -d '"')

# راه‌اندازی تونل Cloudflare
read -p "🔑 Cloudflare Tunnel Token را وارد کنید: " CF_TOKEN
cloudflared service uninstall || true
cloudflared tunnel delete outline-tunnel || true
cloudflared tunnel create outline-tunnel --credentials-file /root/.cloudflared/outline.json
echo "tunnel: outline-tunnel\ncredentials-file: /root/.cloudflared/outline.json\ningress:\n  - hostname: outlinemkh.example.com\n    service: https://localhost:$(echo $API_URL | awk -F':' '{print $3}')\n  - service: http_status:404" > /root/.cloudflared/config.yml
cloudflared tunnel route dns outline-tunnel outlinemkh.example.com
systemctl enable --now cloudflared

# دریافت اطلاعات ربات
read -p "🤖 توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
read -p "📣 لینک کانال بکاپ (با @ یا https): " BACKUP_CHANNEL

ADMIN_IDS=()
while true; do
    read -p "👤 آیدی عددی مدیر را وارد کنید (یا n برای اتمام): " ADMIN_ID
    if [ "$ADMIN_ID" = "n" ]; then break; fi
    ADMIN_IDS+=("$ADMIN_ID")
done
ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"

BACKUP_CHANNEL_ID="null"
if [[ "$BACKUP_CHANNEL" =~ ^https ]]; then
    read -p "🔢 آیدی عددی کانال خصوصی (مثال: -1001234567890): " BACKUP_CHANNEL_ID
fi

# ذخیره فایل تنظیمات
cat <<EOF > /opt/outline_bot/.config.json
{
    "OUTLINE_API_URL": "$API_URL",
    "OUTLINE_API_KEY": "",
    "CERT_SHA256": "$CERT_SHA256",
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_IDS": $ADMIN_IDS_STR,
    "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
    "BACKUP_CHANNEL_ID": "$BACKUP_CHANNEL_ID"
}
EOF

# نصب کتابخانه‌های پایتون
pip install --upgrade pip
pip install requests python-telegram-bot pytz "python-telegram-bot[job-queue]"

# ساخت پوشه لاگ
mkdir -p /opt/outline_bot/logs
touch /opt/outline_bot/logs/bot.log

# اطمینان از وجود فایل JSON
if [ ! -f /opt/outline_bot/users_data.json ]; then
    echo '{"next_id": 1, "users": {}}' > /opt/outline_bot/users_data.json
fi

# کران جاب حذف کاربران منقضی‌شده
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/delete_user.py") | crontab -

# سرویس systemd
cat <<EOL > /etc/systemd/system/outline_bot.service
[Unit]
Description=Outline Bot Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/outline_bot
ExecStart=/opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/outline_bot.py
Restart=always
TimeoutStopSec=10
StandardOutput=append:/opt/outline_bot/service.log
StandardError=append:/opt/outline_bot/service.log

[Install]
WantedBy=multi-user.target
EOL

timedatectl set-timezone Asia/Tehran
systemctl daemon-reload
systemctl enable --now outline_bot

echo "✅ نصب کامل شد. ربات و تونل Cloudflare فعال هستند."
