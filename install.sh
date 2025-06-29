#!/bin/bash

# به‌روزرسانی پکیج‌ها و نصب ابزارهای پایه
apt update && apt upgrade -y
apt install -y python3 python3-pip python3-venv curl jq docker.io

# شروع و فعال‌سازی داکر
systemctl start docker
systemctl enable docker

# ایجاد محیط مجازی پایتون
mkdir -p /opt/outline_bot/outline_env
python3 -m venv /opt/outline_bot/outline_env
source /opt/outline_bot/outline_env/bin/activate

# دانلود فایل‌های مورد نیاز
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
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)" || {
  echo "❌ نصب Outline با خطا مواجه شد."
  exit 1
}

# نصب cloudflared در صورت نیاز
if ! command -v cloudflared &>/dev/null; then
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  dpkg -i cloudflared-linux-amd64.deb
fi

# ورود به کلادفلر
echo "لطفاً وارد حساب Cloudflare شوید..."
cloudflared tunnel login

# تعریف دامنه پایه و ساب‌دامین
ROOT_DOMAIN="vpnmkh.com"
PREFIX="mkhpnora"
FULL_SUBDOMAIN="$PREFIX.$ROOT_DOMAIN"

# بررسی تونل‌های موجود
EXISTING_TUNNELS=$(cloudflared tunnel list -o json | jq -r '.[].name')
TUNNEL_EXISTS=false
for TUN in $EXISTING_TUNNELS; do
  if [[ "$TUN" == "$PREFIX" ]]; then
    TUNNEL_EXISTS=true
    break
  fi
done

if $TUNNEL_EXISTS; then
  echo "⚠️ تونل '$PREFIX' قبلاً وجود دارد."
  read -p "آیا حذف و جایگزین شود؟ (y/n): " DELETE_EXISTING
  if [[ "$DELETE_EXISTING" =~ ^[Yy]$ ]]; then
    cloudflared tunnel delete $PREFIX
    cloudflared tunnel cleanup
  else
    i=1
    while cloudflared tunnel list -o json | jq -r '.[].name' | grep -q "${PREFIX}${i}"; do
      ((i++))
    done
    PREFIX="${PREFIX}${i}"
    FULL_SUBDOMAIN="$PREFIX.$ROOT_DOMAIN"
    echo "📛 تونل جدید انتخاب شد: $PREFIX"
  fi
fi

# ساخت تونل جدید
cloudflared tunnel create $PREFIX
TUNNEL_ID=$(cat /root/.cloudflared/*.json | jq -r "select(.tunnel_id != null and .TunnelName == \"$PREFIX\") | .tunnel_id")
TUNNEL_FILE=$(ls /root/.cloudflared/*.json | grep "$TUNNEL_ID")

# ساخت فایل config.yml
cat <<EOF > /root/.cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_FILE

ingress:
  - hostname: $FULL_SUBDOMAIN
    service: http://localhost:15978
  - service: http_status:404
EOF

# اتصال دامنه به DNS
cloudflared tunnel route dns $PREFIX $FULL_SUBDOMAIN

# ایجاد سرویس systemd برای cloudflared
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Restart=always
ExecStart=$(which cloudflared) tunnel run $PREFIX

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

# استخراج API و certSha256 از access.txt
CERT_SHA256=$(grep "certSha256:" /opt/outline/access.txt | cut -d':' -f2)
API_PORT=$(grep "apiUrl:" /opt/outline/access.txt | awk -F':' '{print $4}')
OUTLINE_API_URL="https://$FULL_SUBDOMAIN:$API_PORT"

# نمایش
echo "CERT_SHA256: $CERT_SHA256"
echo "OUTLINE_API_URL: $OUTLINE_API_URL"

# ایجاد فایل .config.json
cat <<EOF > /opt/outline_bot/.config.json
{
  "OUTLINE_API_URL": "$OUTLINE_API_URL",
  "CERT_SHA256": "$CERT_SHA256"
}
EOF
chmod 600 /opt/outline_bot/.config.json

# دریافت تنظیمات تلگرام
read -p "🔑 توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
ADMIN_IDS=()
while true; do
  read -p "🔹 آیدی عددی ادمین (یا n برای پایان): " ID
  [[ "$ID" == "n" ]] && break
  ADMIN_IDS+=("$ID")
done

if [ ${#ADMIN_IDS[@]} -eq 0 ]; then
  ADMIN_IDS_STR="[]"
else
  ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
  ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"
fi

# دریافت کانال بکاپ
while true; do
  read -p "📣 لینک کانال تلگرام برای بکاپ: " BACKUP_CHANNEL
  BACKUP_CHANNEL=$(echo "$BACKUP_CHANNEL" | tr -d ' ')
  if [[ "$BACKUP_CHANNEL" =~ ^@([a-zA-Z0-9_]{5,32})$ ]]; then
    BACKUP_CHANNEL_ID="null"
    break
  elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+[a-zA-Z0-9_-]+$ ]]; then
    while true; do
      read -p "🔢 آیدی عددی کانال خصوصی (مثلاً -1001234567890): " BACKUP_CHANNEL_ID
      [[ "$BACKUP_CHANNEL_ID" =~ ^-100[0-9]{9,10}$ ]] && break
    done
    break
  fi
done

jq ". + { \"BOT_TOKEN\": \"$BOT_TOKEN\", \"ADMIN_IDS\": $ADMIN_IDS_STR, \"BACKUP_CHANNEL\": \"$BACKUP_CHANNEL\", \"BACKUP_CHANNEL_ID\": \"$BACKUP_CHANNEL_ID\" }" /opt/outline_bot/.config.json > tmp.$$.json && mv tmp.$$.json /opt/outline_bot/.config.json

# نصب پکیج‌ها
pip install --upgrade pip
pip install requests python-telegram-bot pytz "python-telegram-bot[job-queue]"

# آماده‌سازی
mkdir -p /opt/outline_bot/logs
touch /opt/outline_bot/logs/bot.log
[ ! -f /opt/outline_bot/users_data.json ] && echo '{"next_id": 1, "users": {}}' > /opt/outline_bot/users_data.json

# cron job حذف کاربران منقضی‌شده
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/delete_user.py") | crontab -

# ساخت سرویس برای بات
cat <<EOF > /etc/systemd/system/outline_bot.service
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

timedatectl set-timezone Asia/Tehran
systemctl daemon-reload
systemctl enable outline_bot
systemctl start outline_bot

echo "✅ نصب کامل شد. سرور و بات آماده‌اند."
