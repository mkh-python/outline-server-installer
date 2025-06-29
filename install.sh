#!/bin/bash

# فایل نصب وابستگی‌ها و راه‌اندازی ربات Outline

# به‌روزرسانی پکیج منیجر و نصب ابزارهای پایه‌ای
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv curl jq

# نصب Docker
echo "در حال نصب Docker..."
sudo apt install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# ایجاد محیط مجازی پایتون
echo "ایجاد محیط مجازی..."
mkdir -p /opt/outline_bot/outline_env
python3 -m venv /opt/outline_bot/outline_env

# فعال‌سازی محیط مجازی
source /opt/outline_bot/outline_env/bin/activate

# دانلود فایل‌های ربات
echo "در حال دانلود فایل‌های مربوط به ربات..."
mkdir -p /opt/outline_bot
cd /opt/outline_bot

wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/outline_bot.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/delete_user.py
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/users_data.json
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/update.sh
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/README.md
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/version.txt
wget -q https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/install.sh

# بررسی دانلود فایل‌ها
if [ ! -f "outline_bot.py" ] || [ ! -f "delete_user.py" ] || [ ! -f "users_data.json" ] || [ ! -f "update.sh" ]; then
    echo "خطا در دانلود فایل‌های ربات. لطفاً اتصال اینترنت را بررسی کنید."
    exit 1
fi

# اطمینان از مجوز اجرای فایل‌ها
chmod +x *.py
chmod +x update.sh

# نصب سرور Outline
echo "در حال نصب سرور Outline..."
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

# بررسی موفقیت نصب و دریافت API Key
if [ $? -eq 0 ]; then
    echo "سرور Outline با موفقیت نصب شد."
else
    echo "خطا در نصب سرور Outline."
    exit 1
fi

# پرسیدن دامین از کاربر
# 📦 نصب cloudflared (در صورت نصب نبودن)
if ! command -v cloudflared &> /dev/null; then
    echo "در حال نصب Cloudflare Tunnel..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared-linux-amd64.deb
fi

# 🔐 احراز هویت اولیه با Cloudflare
echo "لطفاً پنجره مرورگر را باز کرده و دامنه خود را در Cloudflare تأیید کنید."
cloudflared tunnel login

# دریافت نام دامنه
read -p "لطفاً دامنه اصلی خود را وارد کنید (مثلاً vpnmkh.com): " ROOT_DOMAIN
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
    echo "تونلی با نام '$PREFIX' از قبل وجود دارد."
    read -p "آیا می‌خواهید آن را حذف کرده و جدید بسازید؟ (y/n): " DELETE_EXISTING

    if [[ "$DELETE_EXISTING" =~ ^[Yy](es|ES)?$ ]]; then
        echo "حذف تونل قبلی..."
        cloudflared tunnel delete $PREFIX
        cloudflared tunnel cleanup
    else
        # پیدا کردن نام آزاد بعدی
        i=1
        while cloudflared tunnel list -o json | jq -r '.[].name' | grep -q "${PREFIX}${i}"; do
            ((i++))
        done
        PREFIX="${PREFIX}${i}"
        FULL_SUBDOMAIN="$PREFIX.$ROOT_DOMAIN"
        echo "✅ تونل جدید با نام: $PREFIX"
    fi
fi

# ساخت تونل جدید
cloudflared tunnel create $PREFIX
TUNNEL_ID=$(cat /root/.cloudflared/${PREFIX}.json | jq -r .tunnel_id)

# ساخت فایل کانفیگ tunnel برای روت کردن همه پورت‌ها
mkdir -p /root/.cloudflared
cat <<EOF > /root/.cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/${PREFIX}.json

ingress:
  - hostname: $FULL_SUBDOMAIN
    service: http://localhost:15978
  - service: http_status:404
EOF

# اتصال ساب‌دامین به Cloudflare DNS
cloudflared tunnel route dns $PREFIX $FULL_SUBDOMAIN

# اجرای دائمی سرویس تونل
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared

# نمایش دامنه نهایی
API_URL="https://$FULL_SUBDOMAIN"
read -p "آیا دامین دارید؟ (y/n): " HAS_DOMAIN
if [[ "$HAS_DOMAIN" =~ ^[Yy](es|ES)?$ ]]; then
    read -p "لطفاً دامین خود را وارد کنید: " DOMAIN_NAME

    # استخراج IP دامین (فقط IPv4)
    DOMAIN_IP=$(ping -4 -c 1 "$DOMAIN_NAME" | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -n 1)

    # استخراج IP سرور (فقط IPv4)
    SERVER_IP=$(curl -4 -s icanhazip.com)

    # بررسی هماهنگی IP دامین با IP سرور
    if [ "$DOMAIN_IP" == "$SERVER_IP" ]; then
        echo "دامین با IP سرور هماهنگ است. ادامه می‌دهیم..."
        API_URL="https://$DOMAIN_NAME"
    else
        echo "خطا: دامین وارد شده با IP سرور هماهنگ نیست. لطفاً بررسی کنید."
        echo "دامین وارد شده: $DOMAIN_NAME"
        echo "IP دامین: $DOMAIN_IP"
        echo "IP سرور: $SERVER_IP"
        exit 1
    fi
else
    # اگر کاربر دامین نداشت، استفاده از IP سرور
    SERVER_IP=$(curl -4 -s ifconfig.me)
    API_URL="https://$SERVER_IP"
fi

# استخراج مقادیر certSha256 و apiUrl از فایل access.txt
CERT_SHA256=$(grep "certSha256:" /opt/outline/access.txt | cut -d':' -f2)
OUTLINE_API_URL="$API_URL:$(grep "apiUrl:" /opt/outline/access.txt | awk -F':' '{print $4}')"

# بررسی استخراج موفقیت‌آمیز داده‌ها
if [ -z "$CERT_SHA256" ] || [ -z "$OUTLINE_API_URL" ]; then
    echo "خطا در استخراج اطلاعات از فایل access.txt. لطفاً فایل را بررسی کنید."
    cat /opt/outline/access.txt
    exit 1
fi

# نمایش اطلاعات استخراج‌شده
echo "CERT_SHA256: $CERT_SHA256"
echo "OUTLINE_API_URL: $OUTLINE_API_URL"

# ایجاد فایل تنظیمات مخفی
CONFIG_FILE="/opt/outline_bot/.config.json"
cat <<EOF > $CONFIG_FILE
{
    "OUTLINE_API_URL": "$OUTLINE_API_URL",
    "OUTLINE_API_KEY": "$OUTLINE_API_KEY",
    "CERT_SHA256": "$CERT_SHA256"
}
EOF
chmod 600 $CONFIG_FILE

# دریافت توکن تلگرام
read -p "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN

# دریافت آیدی مدیران
ADMIN_IDS=()
while true; do
    read -p "لطفاً آیدی عددی مدیر را وارد کنید (یا n برای اتمام): " ADMIN_ID
    if [ "$ADMIN_ID" = "n" ]; then
        break
    fi
    if [[ ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        echo "خطا: لطفاً یک آیدی عددی معتبر وارد کنید."
        continue
    fi
    ADMIN_IDS+=("$ADMIN_ID")
done

if [ ${#ADMIN_IDS[@]} -eq 0 ]; then
    ADMIN_IDS_STR="[]"
else
    ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
    ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"
fi

# دریافت لینک کانال برای بکاپ خودکار
while true; do
    read -p "لطفاً لینک کانال تلگرام خود را برای بکاپ خودکار وارد کنید (عمومی یا خصوصی): " BACKUP_CHANNEL
    BACKUP_CHANNEL=$(echo "$BACKUP_CHANNEL" | tr -d ' ')

    if [[ "$BACKUP_CHANNEL" =~ ^@([a-zA-Z0-9_]{5,32})$ ]]; then
        echo "✅ کانال عمومی تایید شد: $BACKUP_CHANNEL"
        BACKUP_CHANNEL_ID="null"
        break
    elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+[a-zA-Z0-9_-]+$ ]]; then
        echo "✅ لینک کانال خصوصی تایید شد: $BACKUP_CHANNEL"
        
        while true; do
            read -p "🔢 لطفاً آیدی عددی کانال خصوصی خود را وارد کنید (مانند -1001234567890): " BACKUP_CHANNEL_ID
            
            if [[ "$BACKUP_CHANNEL_ID" =~ ^-100[0-9]{9,10}$ ]]; then
                echo "✅ آیدی عددی تایید شد: $BACKUP_CHANNEL_ID"
                break
            else
                echo "❌ خطا: لطفاً آیدی عددی معتبر وارد کنید."
            fi
        done
        break
    else
        echo "❌ خطا: فرمت لینک وارد شده صحیح نیست. لطفاً مجدداً تلاش کنید."
    fi
done

# ذخیره اطلاعات در فایل تنظیمات
CONFIG_FILE="/opt/outline_bot/.config.json"
jq ". + { \"BOT_TOKEN\": \"$BOT_TOKEN\", \"ADMIN_IDS\": $ADMIN_IDS_STR, \"BACKUP_CHANNEL\": \"$BACKUP_CHANNEL\", \"BACKUP_CHANNEL_ID\": \"$BACKUP_CHANNEL_ID\" }" $CONFIG_FILE > tmp.$$.json && mv tmp.$$.json $CONFIG_FILE



# ارسال پیام خوش‌آمدگویی به تلگرام
echo -e "${CYAN}Sending welcome message to the user...${RESET}"
curl -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
     -d "chat_id=${ADMIN_IDS[0]}" \
     -d "text=🚀 نصب سرور با موفقیت انجام شد.
نسخه فعلی: 1.37.3

********

API URL from Outline Server:

{"apiUrl":"$OUTLINE_API_URL","certSha256":"$CERT_SHA256"}

🚀 لطفاً مقادیر بالا را در Outline Manager وارد کنید تا به سرور متصل شوید🚀

🡇 لینک دانلود همه سیستم‌عامل‌ها برای مدیریت سرور و کاربران🡇

**********
📥لینک دانلود ویندوز🖥️:
https://s3.amazonaws.com/outline-releases/manager/windows/stable/Outline-Manager.exe
*******
📥لینک دانلود مک🍎:
https://s3.amazonaws.com/outline-releases/manager/macos/stable/Outline-Manager.dmg
*******
📥لینک دانلود لینوکس📱:
https://s3.amazonaws.com/outline-releases/manager/linux/stable/Outline-Manager.AppImage
*******


📂 لطفاً اطمینان حاصل کنید که ربات در این کانال به عنوان **ادمین** اضافه شده است تا بتواند بکاپ‌ها را ارسال کند.


با تشکر از نصب شما! لطفاً حمایت ما را فراموش نکنید.
آیدی پشتیبانی 24 ساعته ربات ما:
@irannetwork_co"

# نصب کتابخانه‌های پایتون موردنیاز
pip install --upgrade pip
pip install requests python-telegram-bot pytz
pip install "python-telegram-bot[job-queue]"

# ساخت فایل log برای ذخیره لاگ‌ها
mkdir -p /opt/outline_bot/logs
touch /opt/outline_bot/logs/bot.log

# اطمینان از دسترسی فایل JSON
if [ ! -f /opt/outline_bot/users_data.json ]; then
    echo '{"next_id": 1, "users": {}}' > /opt/outline_bot/users_data.json
fi

# تنظیم cron job برای حذف کاربران منقضی‌شده
echo "تنظیم Cron برای حذف کاربران منقضی‌شده..."
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/outline_bot/outline_env/bin/python3 /opt/outline_bot/delete_user.py") | crontab -

# ایجاد سرویس Systemd برای اجرای خودکار ربات
SERVICE_FILE="/etc/systemd/system/outline_bot.service"

sudo bash -c "cat > $SERVICE_FILE" <<EOL
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

# بارگذاری و فعال‌سازی سرویس
sudo timedatectl set-timezone Asia/Tehran
sudo systemctl daemon-reload
sudo systemctl enable outline_bot.service
sudo systemctl start outline_bot.service

# پیام پایان نصب
echo "نصب و راه‌اندازی ربات و سرور Outline کامل شد. سرویس به صورت خودکار اجرا شده است."
