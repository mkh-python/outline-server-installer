#!/bin/bash

set -e

echo "🔐 در حال نصب Cloudflare Tunnel..."

# نصب پکیج‌های موردنیاز
apt update && apt install -y curl wget sudo gnupg lsb-release unzip jq

# نصب Docker اگر نبود
if ! command -v docker &>/dev/null; then
  echo "> Verifying that Docker is installed .......... NOT INSTALLED"
  read -p "> Would you like to install Docker? This will run 'curl https://get.docker.com/ | sh'. [Y/n] " confirm
  if [[ $confirm =~ ^[Yy]$ || $confirm == "" ]]; then
    curl -fsSL https://get.docker.com | sh
  else
    echo "❌ Docker لازم است. نصب لغو شد."; exit 1
  fi
fi

echo "> Verifying Docker installation .....OK"

# نصب cloudflared
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# گرفتن اطلاعات
read -p "لطفاً نام دامنه اصلی خود را وارد کنید (مثلاً iritjob.ir): " DOMAIN
SUBDOMAIN="outlinemkh"
FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"

# ورود به اکانت Cloudflare
echo "🌐 ورود به حساب Cloudflare برای ایجاد تونل..."
cloudflared tunnel login

# حذف تونل قبلی اگر وجود دارد
EXISTING_ID=$(cloudflared tunnel list --output json | jq -r '.[] | select(.name=="outline-tunnel") | .id')

if [[ -n "$EXISTING_ID" ]]; then
  echo "🔁 بررسی وجود تونل قبلی با نام outline-tunnel..."
  echo "⚠️ تونل قبلی پیدا شد. در حال حذف..."
  cloudflared tunnel delete outline-tunnel || true
  rm -f /root/.cloudflared/outline-tunnel.json || true
fi

# ساخت تونل جدید
cloudflared tunnel create outline-tunnel

# ساخت فایل تنظیمات cloudflared
CREDENTIAL_PATH=$(find /root/.cloudflared -name "*.json" | grep outline-tunnel | head -n 1)
mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml <<EOF
tunnel: outline-tunnel
credentials-file: ${CREDENTIAL_PATH}
ingress:
  - hostname: ${FULL_DOMAIN}
    service: https://localhost
  - service: http_status:404
EOF

# اضافه‌کردن روت دامنه در کلادفلر
cloudflared tunnel route dns outline-tunnel "$FULL_DOMAIN"

# ساخت سرویس systemd
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared tunnel run --config /etc/cloudflared/config.yml
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable cloudflared
systemctl restart cloudflared

# نصب Outline
echo "⚙️ نصب سرور Outline..."
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# نمایش موفقیت
echo "✅ نصب کامل شد. ربات روی https://${FULL_DOMAIN} فعال شده و تمام ترافیک Outline از طریق Cloudflare Tunnel عبور می‌کند."
