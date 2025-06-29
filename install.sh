#!/bin/bash

set -e

# رنگ‌ها
CYAN='\033[1;36m'
GREEN='\033[1;32m'
RESET='\033[0m'

echo -e "${CYAN}🚀 نصب پیش‌نیازها...${RESET}"
apt update && apt upgrade -y
apt install -y python3 python3-pip python3-venv curl jq docker.io git

echo -e "${CYAN}🐳 راه‌اندازی Docker...${RESET}"
systemctl start docker
systemctl enable docker

echo -e "${CYAN}🌐 نصب Cloudflared و ورود به حساب Cloudflare...${RESET}"
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O cloudflared.deb
dpkg -i cloudflared.deb || apt install -f -y

read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " MAIN_DOMAIN
SUB_DOMAIN="outlinemkh.$MAIN_DOMAIN"

cloudflared login

# حذف تونل قبلی اگر وجود داشته باشد
if cloudflared tunnel list | grep -q "outline-tunnel"; then
    echo -e "⚠️ تونل قبلی با نام outline-tunnel پیدا شد. در حال حذف..."
    cloudflared tunnel delete outline-tunnel || true
fi

TUNNEL_ID=$(cloudflared tunnel create outline-tunnel | grep 'Tunnel credentials written' | awk '{print $NF}')
TUNNEL_UUID=$(basename "$TUNNEL_ID")

mkdir -p /etc/cloudflared
cat <<EOF > /etc/cloudflared/config.yml
tunnel: outline-tunnel
credentials-file: /root/.cloudflared/${TUNNEL_UUID}
ingress:
  - hostname: $SUB_DOMAIN
    service: https://localhost
  - service: http_status:404
EOF

cloudflared tunnel route dns outline-tunnel "$SUB_DOMAIN"
cloudflared service install

echo -e "${GREEN}✅ Cloudflare Tunnel راه‌اندازی شد روی https://$SUB_DOMAIN${RESET}"

echo -e "${CYAN}📦 نصب Outline Server...${RESET}"
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

ACCESS_JSON=$(find /opt/outline/access.txt -type f 2>/dev/null)
if [[ -z "$ACCESS_JSON" ]]; then
    echo "❌ فایل access.txt یافت نشد."
    exit 1
fi

API_URL=$(grep apiUrl "$ACCESS_JSON" | cut -d'"' -f4)
CERT_SHA256=$(grep certSha256 "$ACCESS_JSON" | cut -d'"' -f4)

# جایگزینی دامنه به جای IP در API URL
API_DOMAIN_URL=$(echo "$API_URL" | sed "s|https://[0-9\.]*|https://$SUB_DOMAIN|")

echo -e "${GREEN}✅ اطلاعات استخراج شد:${RESET}"
echo "API: $API_DOMAIN_URL"
echo "Cert: $CERT_SHA256"

# نصب و تنظیم ربات
mkdir -p /opt/outline_bot
cd /opt/outline_bot

echo -e "${CYAN}📥 دانلود سورس ربات...${RESET}"
git clone https://github.com/mkh-python/outline-server-installer.git tmp_bot
cp tmp_bot/*.py . && cp tmp_bot/*.json . && cp tmp_bot/*.sh . || true
rm -rf tmp_bot

python3 -m venv outline_env
source outline_env/bin/activate
pip install --upgrade pip
pip install requests python-telegram-bot "python-telegram-bot[job-queue]" pytz

read -p "🤖 توکن ربات تلگرام: " BOT_TOKEN

ADMIN_IDS=()
while true; do
    read -p "➕ آیدی عددی مدیر (یا 'n' برای پایان): " ADMIN_ID
    [[ "$ADMIN_ID" == "n" ]] && break
    [[ "$ADMIN_ID" =~ ^[0-9]+$ ]] && ADMIN_IDS+=("$ADMIN_ID") || echo "❌ آیدی نامعتبر"
done
ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"

while true; do
    read -p "📢 لینک کانال بکاپ (عمومی یا خصوصی): " BACKUP_CHANNEL
    BACKUP_CHANNEL=$(echo "$BACKUP_CHANNEL" | tr -d ' ')
    if [[ "$BACKUP_CHANNEL" =~ ^@([a-zA-Z0-9_]{5,32})$ ]]; then
        BACKUP_CHANNEL_ID="null"
        break
    elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+[a-zA-Z0-9_-]+$ ]]; then
        read -p "🔢 آیدی عددی کانال (مثلاً -1001234567890): " BACKUP_CHANNEL_ID
        break
    else
        echo "❌ فرمت لینک نامعتبر"
    fi
done

cat <<EOF > /opt/outline_bot/.config.json
{
    "OUTLINE_API_URL": "$API_DOMAIN_URL",
    "OUTLINE_API_KEY": "",
    "CERT_SHA256": "$CERT_SHA256",
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_IDS": $ADMIN_IDS_STR,
    "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
    "BACKUP_CHANNEL_ID": $BACKUP_CHANNEL_ID
}
EOF

mkdir -p /opt/outline_bot/logs
touch /opt/outline_bot/logs/bot.log

echo -e "${CYAN}⚙️ ایجاد سرویس systemd...${RESET}"
cat <<EOF > /etc/systemd/system/outline_bot.service
[Unit]
Description=Outline Bot Service
After=network.target

[Service]
WorkingDirectory=/opt/outline_bot
ExecStart=/opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/outline_bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable outline_bot
systemctl restart outline_bot

echo -e "${GREEN}✅ نصب کامل شد. ربات فعال است و سرور روی https://$SUB_DOMAIN راه‌اندازی شده است.${RESET}"
