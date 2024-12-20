#!/bin/bash

LOG_FILE="/opt/outline_bot/update.log"
exec > >(tee -a $LOG_FILE) 2>&1

# مسیرهای اصلی
BOT_DIR="/opt/outline_bot"
BACKUP_DIR="$BOT_DIR/backup_$(date +%Y%m%d_%H%M%S)"
GITHUB_REPO_URL="https://raw.githubusercontent.com/mkh-python/outline-server-installer/main"
FILES=("outline_bot.py" "delete_user.py" "install.sh")

# بررسی نسخه فعلی و جدید
if [ ! -f "$BOT_DIR/version.txt" ]; then
    echo "فایل version.txt یافت نشد. نسخه فعلی: ناشناخته"
    CURRENT_VERSION=""
else
    CURRENT_VERSION=$(cat "$BOT_DIR/version.txt")
fi

REMOTE_VERSION=$(curl -s "$GITHUB_REPO_URL/version.txt")

if [ "$CURRENT_VERSION" == "$REMOTE_VERSION" ]; then
    echo "شما از آخرین نسخه استفاده می‌کنید ($CURRENT_VERSION)."
    exit 0
fi

echo "نسخه جدید یافت شد: $REMOTE_VERSION (نسخه فعلی: $CURRENT_VERSION)"
echo "به‌روزرسانی آغاز می‌شود..."

# ایجاد بکاپ از فایل‌های حساس
echo "ایجاد بکاپ از فایل‌های حساس..."
mkdir -p "$BACKUP_DIR"
cp "$BOT_DIR/users_data.json" "$BACKUP_DIR/users_data.json.bak"
cp "$BOT_DIR/.config.json" "$BACKUP_DIR/.config.json.bak"

# دانلود و جایگزینی فایل‌های جدید و فایل‌های جدیدی که در سرور نیستند
echo "دانلود و جایگزینی فایل‌های جدید..."
REMOTE_FILES=$(curl -s "$GITHUB_REPO_URL/files_list.txt")
for FILE in $REMOTE_FILES; do
    if [ ! -f "$BOT_DIR/$FILE" ]; then
        echo "فایل $FILE در سرور یافت نشد. در حال دانلود..."
        curl -s -o "$BOT_DIR/$FILE" "$GITHUB_REPO_URL/$FILE"
        if [ $? -eq 0 ]; then
            echo "فایل $FILE با موفقیت دانلود و اضافه شد."
        else
            echo "خطا در دانلود فایل $FILE. عملیات متوقف شد."
            # اطلاع‌رسانی به کاربر در صورت خطا در دانلود
            BOT_TOKEN=$(jq -r '.BOT_TOKEN' "$BOT_DIR/.config.json")
            ADMIN_ID=$(jq -r '.ADMIN_IDS[0]' "$BOT_DIR/.config.json")
            curl -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d "chat_id=$ADMIN_ID" \
                -d "text=❌ خطا در دانلود فایل $FILE. عملیات متوقف شد."
            exit 1
        fi
    else
        echo "فایل $FILE قبلاً موجود است. بررسی به‌روزرسانی..."
        curl -s -o "$BOT_DIR/$FILE" "$GITHUB_REPO_URL/$FILE"
        if [ $? -eq 0 ]; then
            echo "فایل $FILE با موفقیت به‌روزرسانی شد."
        else
            echo "خطا در به‌روزرسانی فایل $FILE."
            BOT_TOKEN=$(jq -r '.BOT_TOKEN' "$BOT_DIR/.config.json")
            ADMIN_ID=$(jq -r '.ADMIN_IDS[0]' "$BOT_DIR/.config.json")
            curl -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
                -d "chat_id=$ADMIN_ID" \
                -d "text=❌ خطا در به‌روزرسانی فایل $FILE. لطفاً بررسی کنید."
            exit 1
        fi
    fi
done

# عدم تغییر فایل‌های حساس
echo "اطمینان از عدم تغییر فایل‌های حساس..."
if [ -f "$BACKUP_DIR/users_data.json.bak" ]; then
    mv "$BACKUP_DIR/users_data.json.bak" "$BOT_DIR/users_data.json"
fi

if [ -f "$BACKUP_DIR/.config.json.bak" ]; then
    mv "$BACKUP_DIR/.config.json.bak" "$BOT_DIR/.config.json"
fi

# به‌روزرسانی نسخه
echo "$REMOTE_VERSION" > "$BOT_DIR/version.txt"

# ری‌استارت سرویس ربات
echo "ری‌استارت سرویس..."
sudo systemctl restart outline_bot.service
if [ $? -ne 0 ]; then
    echo "خطا در ری‌استارت سرویس."
    BOT_TOKEN=$(jq -r '.BOT_TOKEN' "$BOT_DIR/.config.json")
    ADMIN_ID=$(jq -r '.ADMIN_IDS[0]' "$BOT_DIR/.config.json")
    curl -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$ADMIN_ID" \
        -d "text=❌ خطا در فرآیند به‌روزرسانی. لطفاً لاگ‌ها را بررسی کنید یا به صورت دستی اقدام کنید."
    exit 1
fi

# اطلاع‌رسانی به کاربر در صورت موفقیت به‌روزرسانی
BOT_TOKEN=$(jq -r '.BOT_TOKEN' "$BOT_DIR/.config.json")
ADMIN_ID=$(jq -r '.ADMIN_IDS[0]' "$BOT_DIR/.config.json")
curl -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$ADMIN_ID" \
    -d "text=🚀 به‌روزرسانی با موفقیت انجام شد! 🌟\n\nنسخه جدید: $REMOTE_VERSION\n\nربات شما اکنون به آخرین نسخه به‌روزرسانی شده است. 🎉"

echo "به‌روزرسانی کامل شد."
