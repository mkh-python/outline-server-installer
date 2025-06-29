#!/bin/bash

# ------------------- بخش 1: نصب وابستگی‌ها -------------------
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv curl jq docker.io

# ------------------- بخش 2: نصب cloudflared -------------------
echo "🔐 در حال نصب Cloudflare Tunnel..."
if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O cloudflared.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
fi

# ------------------- بخش 3: دریافت اطلاعات -------------------
read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " ROOT_DOMAIN
SUBDOMAIN="outlinemkh"
DOMAIN_NAME="${SUBDOMAIN}.${ROOT_DOMAIN}"

read -p "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN

ADMIN_IDS=()
while true; do
    read -p "آیدی عددی مدیر را وارد کنید (یا n برای اتمام): " ADMIN_ID
    [[ "$ADMIN_ID" = "n" ]] && break
    [[ "$ADMIN_ID" =~ ^[0-9]+$ ]] && ADMIN_IDS+=("$ADMIN_ID")
done

if [ ${#ADMIN_IDS[@]} -eq 0 ]; then
    ADMIN_IDS_STR="[]"
else
    ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
    ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"
fi

while true; do
    read -p "لینک کانال بکاپ (عمومی یا خصوصی): " BACKUP_CHANNEL
    BACKUP_CHANNEL=$(echo "$BACKUP_CHANNEL" | tr -d ' ')
    if [[ "$BACKUP_CHANNEL" =~ ^@([a-zA-Z0-9_]{5,32})$ ]]; then
        BACKUP_CHANNEL_ID="null"
        break
    elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/+ ]]; then
        read -p "🔢 آیدی عددی کانال خصوصی را وارد کنید (مثل -1001234567890): " BACKUP_CHANNEL_ID
        break
    fi
done

# ------------------- بخش 4: نصب Outline Server -------------------
echo "⚙️ نصب سرور Outline..."
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# ------------------- بخش 5: استخراج اطلاعات -------------------
CERT_SHA256=$(grep "certSha256:" /opt/outline/access.txt | cut -d':' -f2 | tr -d ' ')
OUTLINE_PORT=$(grep "apiUrl:" /opt/outline/access.txt | awk -F':' '{print $4}' | tr -d '} ')
OUTLINE_API_KEY=$(grep "apiKey:" /opt/outline/access.txt | cut -d':' -f2 | tr -d ' "')
OUTLINE_API_URL="https://${DOMAIN_NAME}:${OUTLINE_PORT}"

# ------------------- بخش 6: راه‌اندازی Cloudflare Tunnel -------------------
echo "🌐 ورود به حساب Cloudflare برای ایجاد تونل..."
cloudflared tunnel login

TUNNEL_NAME="outline-tunnel"
cloudflared tunnel create $TUNNEL_NAME
CREDENTIAL_PATH="/root/.cloudflared/${TUNNEL_NAME}.json"

mkdir -p /etc/cloudflared
cat <<EOF > /etc/cloudflared/config.yml
tunnel: $TUNNEL_NAME
credentials-file: $CREDENTIAL_PATH

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$OUTLINE_PORT
  - service: http_status:404
EOF

cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN_NAME
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

# ------------------- بخش 7: ساخت پیکربندی ربات -------------------
mkdir -p /opt/outline_bot
cat <<EOF > /opt/outline_bot/.config.json
{
  "OUTLINE_API_URL": "$OUTLINE_API_URL",
  "OUTLINE_API_KEY": "$OUTLINE_API_KEY",
  "CERT_SHA256": "$CERT_SHA256",
  "BOT_TOKEN": "$BOT_TOKEN",
  "ADMIN_IDS": $ADMIN_IDS_STR,
  "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
  "BACKUP_CHANNEL_ID": "$BACKUP_CHANNEL_ID"
}
EOF

chmod 600 /opt/outline_bot/.config.json

# ------------------- بخش 8: نصب فایل‌های ربات -------------------
cd /opt/outline_bot
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/outline_bot.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/delete_user.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/update.sh
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/users_data.json
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/version.txt

# ------------------- بخش 9: نصب وابستگی‌های پایتون -------------------
python3 -m venv outline_env
source outline_env/bin/activate
pip install --upgrade pip
pip install requests python-telegram-bot "python-telegram-bot[job-queue]" pytz

# ------------------- بخش 10: اجرای ربات به عنوان سرویس -------------------
cat <<EOF | sudo tee /etc/systemd/system/outline_bot.service
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

sudo systemctl daemon-reload
sudo systemctl enable outline_bot
sudo systemctl start outline_bot

echo "✅ نصب کامل شد. ربات روی ${DOMAIN_NAME} فعال شده و همه ترافیک از تونل عبور می‌کند."
