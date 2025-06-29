#!/bin/bash
set -euo pipefail

# 🎯 بروز رسانی و نصب پیش‌نیازها
apt update && apt upgrade -y
apt install -y python3 python3-pip python3-venv curl jq docker.io wget git build-essential

# ⛳ نصب Cloudflared
echo "🌐 نصب Cloudflared و ورود به حساب Cloudflare..."
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# گرفتن دامنه اصلی
read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " DOMAIN
SUBDOMAIN="outlinemkh"
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

# ورود به حساب Cloudflare
cloudflared tunnel login

# حذف تونل قبلی در صورت وجود
if cloudflared tunnel list | grep -q "outline-tunnel"; then
    echo "⚠️ تونل با نام outline-tunnel وجود دارد. حذف در حال انجام..."
    cloudflared tunnel delete outline-tunnel || true
    rm -f /root/.cloudflared/*.json
fi

# ساخت تونل جدید و دریافت ID
cloudflared tunnel create outline-tunnel | tee tunnel_output.log
TUNNEL_ID=$(grep -oP 'Created tunnel.*id \K[\w-]+' tunnel_output.log)
CREDENTIAL_PATH="/root/.cloudflared/${TUNNEL_ID}.json"

# تنظیم config.yml
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: outline-tunnel
credentials-file: ${CREDENTIAL_PATH}
ingress:
  - hostname: ${FULL_DOMAIN}
    service: https://localhost
  - service: http_status:404
EOF

# اتصال ساب‌دامین
cloudflared tunnel route dns outline-tunnel ${FULL_DOMAIN}

# فعال‌سازی Systemd برای Cloudflared
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared tunnel run outline-tunnel
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

echo "✅ Cloudflare Tunnel راه‌اندازی شد روی https://${FULL_DOMAIN}"

# ⚙️ نصب Outline Server
echo "📦 نصب Outline Server..."
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# استخراج اطلاعات دسترسی
ACCESS_FILE="/opt/outline/access.txt"
CERT_SHA256=$(grep "certSha256:" $ACCESS_FILE | cut -d':' -f2 | tr -d '" ')
API_PORT=$(grep "apiUrl:" $ACCESS_FILE | awk -F':' '{print $4}' | cut -d'/' -f1)
OUTLINE_API_URL="https://${FULL_DOMAIN}:${API_PORT}"
OUTLINE_API_KEY=$(grep -oP '"apiKey":"\K[^"]+' $ACCESS_FILE)

# 📂 تنظیمات ربات
mkdir -p /opt/outline_bot
cd /opt/outline_bot
python3 -m venv outline_env
source outline_env/bin/activate

# دانلود سورس ربات
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/outline_bot.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/delete_user.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/users_data.json
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/update.sh

# نصب پکیج‌ها
pip install --upgrade pip
pip install requests python-telegram-bot pytz "python-telegram-bot[job-queue]"

# دریافت مقادیر از کاربر
read -p "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
ADMIN_IDS=()
while true; do
    read -p "لطفاً آیدی عددی مدیر را وارد کنید (یا n برای پایان): " ID
    [[ "$ID" == "n" ]] && break
    ADMIN_IDS+=("$ID")
done

# کانال بکاپ
while true; do
    read -p "لینک کانال (با @ یا لینک خصوصی): " BACKUP_CHANNEL
    if [[ "$BACKUP_CHANNEL" =~ ^@ ]]; then
        BACKUP_CHANNEL_ID="null"
        break
    elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+ ]]; then
        read -p "🔢 آیدی عددی کانال خصوصی (-100...) را وارد کنید: " BACKUP_CHANNEL_ID
        break
    else
        echo "❌ فرمت نادرست."
    fi
done

# ذخیره فایل کانفیگ
cat > .config.json <<EOF
{
  "OUTLINE_API_URL": "$OUTLINE_API_URL",
  "OUTLINE_API_KEY": "$OUTLINE_API_KEY",
  "CERT_SHA256": "$CERT_SHA256",
  "BOT_TOKEN": "$BOT_TOKEN",
  "ADMIN_IDS": [$(IFS=,; echo "${ADMIN_IDS[*]}")],
  "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
  "BACKUP_CHANNEL_ID": $BACKUP_CHANNEL_ID
}
EOF

# ساخت فولدر لاگ
mkdir -p logs && touch logs/bot.log

# کران‌جاب برای حذف کاربران منقضی‌شده
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/delete_user.py") | crontab -

# فعال‌سازی systemd برای ربات
cat > /etc/systemd/system/outline_bot.service <<EOF
[Unit]
Description=Outline Bot Service
After=network.target

[Service]
WorkingDirectory=/opt/outline_bot
ExecStart=/opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/outline_bot.py
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

timedatectl set-timezone Asia/Tehran
systemctl daemon-reload
systemctl enable outline_bot
systemctl restart outline_bot

# پیام نهایی
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=${ADMIN_IDS[0]}" -d "text=🚀 نصب کامل شد. سرور شما در https://${FULL_DOMAIN} فعال است.\n\n🔐 apiUrl:\n${OUTLINE_API_URL}\nSHA256: ${CERT_SHA256}"
echo "✅ نصب کامل شد. ربات و سرور آماده‌اند."
