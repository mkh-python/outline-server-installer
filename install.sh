#!/bin/bash

# تنظیم Cloudflare Tunnel
echo "در حال پیکربندی Cloudflare Tunnel..."
TUNNEL_NAME="outline-vpn"
LOCAL_PORT=443
HOSTNAME="outline.$(hostname).cloudflared.com"

# حذف فایل گواهی قدیمی در صورت وجود
if [ -f "/root/.cloudflared/cert.pem" ]; then
    echo "حذف فایل گواهی قدیمی..."
    sudo rm -f /root/.cloudflared/cert.pem
fi

# نصب cloudflared در صورت نیاز
if ! command -v cloudflared &> /dev/null; then
    echo "در حال نصب cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    sudo dpkg -i cloudflared.deb
    rm -f cloudflared.deb
fi

# ورود به حساب Cloudflare
echo "ورود به حساب Cloudflare..."
cloudflared login

# حذف تونل قدیمی در صورت وجود
EXISTING_TUNNEL=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')
if [ -n "$EXISTING_TUNNEL" ]; then
    echo "حذف تونل قدیمی $TUNNEL_NAME..."
    cloudflared tunnel delete $TUNNEL_NAME
fi

# ایجاد تونل جدید
echo "ایجاد تونل Cloudflare..."
cloudflared tunnel create $TUNNEL_NAME

# دریافت اطلاعات تونل
TUNNEL_ID=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')
CREDENTIALS_FILE="/root/.cloudflared/${TUNNEL_ID}.json"

# تنظیم فایل پیکربندی تونل
echo "تنظیم فایل پیکربندی تونل..."
sudo mkdir -p /etc/cloudflared
cat <<EOF | sudo tee /etc/cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $HOSTNAME
    service: http://localhost:$LOCAL_PORT
  - service: http_status:404
EOF

# تنظیم رکورد DNS در Cloudflare
echo "تنظیم رکورد DNS در Cloudflare..."
cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME

# ایجاد سرویس Systemd برای تونل
sudo bash -c "cat > /etc/systemd/system/cloudflared.service" <<EOL
[Unit]
Description=Cloudflare Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml run
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

# فعال‌سازی سرویس تونل
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl start cloudflared

echo "پیکربندی Cloudflare Tunnel با موفقیت انجام شد!"
