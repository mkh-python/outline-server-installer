#!/bin/bash

echo "🔐 در حال نصب Cloudflare Tunnel..."

# نصب Cloudflared
apt update && apt install -y curl jq
curl -L -o cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb || apt install -f -y

# دریافت دامنه اصلی
read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " ROOT_DOMAIN
SUBDOMAIN="outlinemkh"
FULL_DOMAIN="${SUBDOMAIN}.${ROOT_DOMAIN}"

# دریافت تنظیمات ربات
read -p "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
ADMINS=()
while true; do
    read -p "آیدی عددی مدیر را وارد کنید (یا n برای اتمام): " ADMIN_ID
    [[ "$ADMIN_ID" == "n" ]] && break
    ADMINS+=("$ADMIN_ID")
done
read -p "لینک کانال بکاپ (عمومی یا خصوصی): " BACKUP_CHANNEL
read -p "🔢 آیدی عددی کانال خصوصی را وارد کنید (مثل -1001234567890): " PRIVATE_CHANNEL

# نصب Outline
echo "⚙️ نصب سرور Outline..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# دریافت اطلاعات Outline
API_URL=$(cat /opt/outline/access.txt | grep apiUrl | cut -d '"' -f4)
CERT_SHA=$(cat /opt/outline/access.txt | grep certSha256 | cut -d '"' -f4)

# ورود به Cloudflare
echo "🌐 ورود به حساب Cloudflare برای ایجاد تونل..."
cloudflared tunnel login

# بررسی و حذف تونل قبلی در صورت وجود
echo "🔁 بررسی وجود تونل قبلی با نام outline-tunnel..."
EXISTING_TUNNEL_ID=$(cloudflared tunnel list --output json 2>/dev/null | jq -r '.[] | select(.name=="outline-tunnel") | .id')
if [[ -n "$EXISTING_TUNNEL_ID" ]]; then
    echo "⚠️ تونل قبلی پیدا شد. در حال حذف..."
    cloudflared tunnel delete outline-tunnel || true
    cloudflared tunnel cleanup || true
    rm -f /root/.cloudflared/outline-tunnel.json
    rm -f /etc/cloudflared/config.yml
    systemctl stop cloudflared 2>/dev/null
    systemctl disable cloudflared 2>/dev/null
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reexec
    echo "✅ تونل قبلی حذف شد."
fi

# ایجاد تونل جدید
cloudflared tunnel create outline-tunnel

# تنظیم config.yml
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: outline-tunnel
credentials-file: /root/.cloudflared/outline-tunnel.json
ingress:
  - hostname: ${FULL_DOMAIN}
    service: https://localhost
  - service: http_status:404
EOF

# اتصال ساب‌دامین به تونل
cloudflared tunnel route dns outline-tunnel ${FULL_DOMAIN}

# نصب و راه‌اندازی سرویس Cloudflared
cloudflared service install
systemctl enable cloudflared
systemctl restart cloudflared

# نصب پکیج‌های مورد نیاز بات
cd /opt
git clone https://github.com/Jigsaw-Code/outline-server.git outline_bot
cd outline_bot
python3 -m venv outline_env
source outline_env/bin/activate
pip install --upgrade pip
pip install python-telegram-bot requests pytz httpx "apscheduler<3.12.0"

# ذخیره تنظیمات در .config.json
cat > /opt/outline_bot/.config.json <<EOF
{
  "BOT_TOKEN": "$BOT_TOKEN",
  "ADMINS": [$(printf '"%s",' "${ADMINS[@]}" | sed 's/,$//')],
  "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
  "PRIVATE_CHANNEL_ID": "$PRIVATE_CHANNEL",
  "OUTLINE_API_URL": "$API_URL",
  "CERT_SHA256": "$CERT_SHA"
}
EOF

# تعریف سرویس systemd برای ربات
cat > /etc/systemd/system/outline_bot.service <<EOF
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
EOF

# اجرای سرویس ربات
systemctl daemon-reload
systemctl enable outline_bot
systemctl start outline_bot

echo "✅ نصب کامل شد. ربات روی https://${FULL_DOMAIN} فعال شده و تمام ترافیک Outline از طریق Cloudflare Tunnel عبور می‌کند."
