#!/bin/bash

# فایل نصب وابستگی‌ها و راه‌اندازی ربات Outline

# به‌روزرسانی پکیج منیجر و نصب ابزارهای پایه‌ای
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv curl jq

# نصب سرور Outline
echo "در حال نصب سرور Outline..."
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh)"

# بررسی موفقیت نصب و دریافت API Key
if [ $? -eq 0 ]; then
    echo "سرور Outline با موفقیت نصب شد."
else
    echo "خطا در نصب سرور Outline."
    exit 1
fi

# استخراج مقادیر certSha256 و apiUrl از فایل access.txt
CERT_SHA256=$(grep "certSha256:" /opt/outline/access.txt | cut -d':' -f2)
OUTLINE_API_URL=$(grep "apiUrl:" /opt/outline/access.txt | awk -F'apiUrl:' '{print $2}')

# بررسی استخراج موفقیت‌آمیز داده‌ها
if [ -z "$CERT_SHA256" ] || [ -z "$OUTLINE_API_URL" ]; then
    echo "خطا در استخراج اطلاعات از فایل access.txt. لطفاً فایل را بررسی کنید."
    cat /opt/outline/access.txt
    exit 1
fi

# استخراج OUTLINE_API_KEY از OUTLINE_API_URL
OUTLINE_API_KEY=$(echo $OUTLINE_API_URL | awk -F'/' '{print $NF}')

# نمایش اطلاعات استخراج‌شده
echo "CERT_SHA256: $CERT_SHA256"
echo "OUTLINE_API_URL: $OUTLINE_API_URL"
echo "OUTLINE_API_KEY: $OUTLINE_API_KEY"

# به‌روزرسانی فایل outline_bot.py
echo "در حال به‌روزرسانی فایل outline_bot.py..."
sed -i "s|OUTLINE_API_URL = .*|OUTLINE_API_URL = \"$OUTLINE_API_URL\"|" outline_bot.py
sed -i "s|OUTLINE_API_KEY = .*|OUTLINE_API_KEY = \"$OUTLINE_API_KEY\"|" outline_bot.py
sed -i "s|CERT_SHA256 = .*|CERT_SHA256 = \"$CERT_SHA256\"|" outline_bot.py

# دریافت توکن تلگرام
read -p "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
sed -i "s|BOT_TOKEN = .*|BOT_TOKEN = \"$BOT_TOKEN\"|" outline_bot.py

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

# تبدیل آرایه به رشته
if [ ${#ADMIN_IDS[@]} -eq 0 ]; then
    ADMIN_IDS_STR="[]"
else
    # استفاده از printf برای تبدیل آرایه به رشته با کاما و فاصله
    ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
    ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"
fi

# جایگزینی متغیر ADMIN_IDS در فایل outline_bot.py
sed -i "s|ADMIN_IDS = .*|ADMIN_IDS = ${ADMIN_IDS_STR}|" outline_bot.py


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

با تشکر از نصب شما! لطفاً حمایت ما را فراموش نکنید.
آیدی پشتیبانی 24 ساعته ربات ما:
@irannetwork_co"


# ایجاد محیط مجازی پایتون
python3 -m venv outline_env

# فعال‌سازی محیط مجازی
source outline_env/bin/activate

# نصب کتابخانه‌های پایتون موردنیاز
pip install --upgrade pip
pip install requests python-telegram-bot

# نصب گواهی‌های SSL در صورت نیاز
sudo apt install -y ca-certificates

# ساخت فایل log برای ذخیره لاگ‌ها
mkdir -p logs
touch logs/bot.log

# اطمینان از دسترسی فایل JSON
if [ ! -f users_data.json ]; then
    echo '{"next_id": 1, "users": {}}' > users_data.json
fi

# ایجاد سرویس Systemd برای اجرای خودکار ربات
SERVICE_FILE="/etc/systemd/system/outline_bot.service"

sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Outline Bot Service
After=network.target

[Service]
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/outline_env/bin/python3 $(pwd)/outline_bot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# بارگذاری و فعال‌سازی سرویس
sudo systemctl daemon-reload
sudo systemctl enable outline_bot.service
sudo systemctl start outline_bot.service

# پیام پایان نصب
echo "نصب و راه‌اندازی ربات و سرور Outline کامل شد. سرویس به صورت خودکار اجرا شده است."