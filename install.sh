#!/bin/bash

# ============================================================
# نصب کامل Outline Server + ربات تلگرام مدیریت Outline
# نسخه نصب تمیز + ویزارد مرحله‌ای
# ============================================================
# این فایل کارهای زیر را انجام می‌دهد:
# 1. پاک‌سازی کامل نصب قبلی ربات و Outline Server
# 2. نصب پیش‌نیازهای سیستم
# 3. نصب Docker
# 4. دانلود فایل‌های ربات از GitHub
# 5. نصب Outline Server
# 6. دریافت دامین یا استفاده از IP
# 7. استخراج apiUrl و certSha256 و API Key
# 8. ساخت فایل .config.json
# 9. دریافت توکن ربات، مدیرها و کانال بکاپ با ویزارد مرحله‌ای
# 10. نصب کتابخانه‌های پایتون
# 11. ساخت سرویس systemd
# ============================================================

set -Eeuo pipefail

# ============================================================
# رنگ‌ها برای نمایش بهتر پیام‌ها
# ============================================================
RESET="\033[0m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"

# ============================================================
# تنظیمات مسیرها و مخزن GitHub
# ============================================================
BOT_DIR="/opt/outline_bot"
VENV_DIR="$BOT_DIR/outline_env"
CONFIG_FILE="$BOT_DIR/.config.json"
SERVICE_FILE="/etc/systemd/system/outline_bot.service"
ACCESS_FILE="/opt/outline/access.txt"

REPO_BASE_URL="https://raw.githubusercontent.com/mkh-python/outline-server-installer/main"

# ============================================================
# توابع کمکی برای نمایش پیام
# ============================================================
print_title() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo -e "${RESET}"
}

print_success() {
    echo -e "${GREEN}✅ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠️ $1${RESET}"
}

print_error() {
    echo -e "${RED}❌ $1${RESET}"
}

# ============================================================
# بررسی اجرای اسکریپت با دسترسی root
# ============================================================
if [ "$EUID" -ne 0 ]; then
    print_error "لطفاً این فایل را با دسترسی root اجرا کنید."
    echo "مثال:"
    echo "sudo bash install.sh"
    exit 1
fi

# ============================================================
# مرحله صفر: پاک‌سازی کامل نصب قبلی
# ============================================================
print_title "مرحله صفر: پاک‌سازی کامل نصب قبلی Outline و ربات تلگرام"

echo "این عملیات موارد زیر را پاک می‌کند:"
echo "- سرویس outline_bot"
echo "- پوشه /opt/outline_bot"
echo "- پوشه /opt/outline"
echo "- کانتینرهای Docker مربوط به Outline"
echo "- کران‌جاب‌های قبلی ربات"
echo ""
echo "هشدار:"
echo "با ادامه این مرحله، کاربران قبلی، access key ها، کانفیگ قبلی و دیتای قبلی کامل پاک می‌شوند."
echo ""

read -rp "آیا از پاک‌سازی کامل و نصب مجدد مطمئن هستید؟ برای ادامه yes بنویسید: " CONFIRM_CLEAN_INSTALL

if [ "$CONFIRM_CLEAN_INSTALL" != "yes" ]; then
    echo "عملیات نصب لغو شد."
    exit 0
fi

echo ""
echo "شروع پاک‌سازی نصب قبلی..."

# ------------------------------------------------------------
# توقف و غیرفعال کردن سرویس ربات
# ------------------------------------------------------------
if systemctl list-unit-files 2>/dev/null | grep -q "^outline_bot.service"; then
    echo "در حال توقف سرویس outline_bot..."
    systemctl stop outline_bot.service 2>/dev/null || true
    systemctl disable outline_bot.service 2>/dev/null || true
fi

# ------------------------------------------------------------
# حذف فایل سرویس systemd ربات
# ------------------------------------------------------------
if [ -f "$SERVICE_FILE" ]; then
    echo "در حال حذف فایل سرویس outline_bot..."
    rm -f "$SERVICE_FILE"
fi

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# ------------------------------------------------------------
# توقف پردازش‌های احتمالی ربات
# ------------------------------------------------------------
# نکته مهم:
# از pkill -f مستقیم استفاده نمی‌کنیم، چون اگر اسکریپت با bash -c اجرا شود،
# ممکن است متن خود اسکریپت داخل command line باشد و نصب‌کننده خودش را kill کند.
# الگوی [/] باعث می‌شود فقط پروسه واقعی فایل اجراشده پیدا شود.
# ------------------------------------------------------------
echo "در حال توقف پردازش‌های احتمالی ربات..."

BOT_PIDS=$(pgrep -f "[/]opt/outline_bot/outline_bot.py" 2>/dev/null || true)
DELETE_USER_PIDS=$(pgrep -f "[/]opt/outline_bot/delete_user.py" 2>/dev/null || true)

if [ -n "$BOT_PIDS" ]; then
    echo "در حال توقف پردازش outline_bot.py ..."
    kill $BOT_PIDS 2>/dev/null || true
fi

if [ -n "$DELETE_USER_PIDS" ]; then
    echo "در حال توقف پردازش delete_user.py ..."
    kill $DELETE_USER_PIDS 2>/dev/null || true
fi

# ------------------------------------------------------------
# حذف کانتینرهای Docker مربوط به Outline
# ------------------------------------------------------------
echo "در حال حذف کانتینرهای Docker مربوط به Outline..."

if command -v docker >/dev/null 2>&1; then
    docker rm -f shadowbox 2>/dev/null || true
    docker rm -f watchtower 2>/dev/null || true

    OUTLINE_CONTAINERS=$(docker ps -aq --filter "name=shadowbox" --filter "name=watchtower" 2>/dev/null || true)

    if [ -n "$OUTLINE_CONTAINERS" ]; then
        docker rm -f $OUTLINE_CONTAINERS 2>/dev/null || true
    fi

    echo "در حال حذف ایمیج‌های Docker مربوط به Outline..."

    OUTLINE_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" 2>/dev/null | grep -Ei "outline|shadowbox|watchtower" | awk '{print $2}' | sort -u || true)

    if [ -n "$OUTLINE_IMAGES" ]; then
        docker rmi -f $OUTLINE_IMAGES 2>/dev/null || true
    fi

    echo "در حال پاک‌سازی Docker network های بدون استفاده..."
    docker network prune -f 2>/dev/null || true

    echo "در حال پاک‌سازی Docker volume های بدون استفاده..."
    docker volume prune -f 2>/dev/null || true
else
    print_warning "Docker هنوز نصب نیست یا در دسترس نیست؛ پاک‌سازی Docker رد شد."
fi

# ------------------------------------------------------------
# حذف پوشه کامل Outline Server
# ------------------------------------------------------------
if [ -d /opt/outline ]; then
    echo "در حال حذف پوشه /opt/outline ..."
    rm -rf /opt/outline
fi

# ------------------------------------------------------------
# حذف فایل‌های لاگ قدیمی احتمالی
# ------------------------------------------------------------
rm -f /var/log/outline_bot.log 2>/dev/null || true

print_success "پاک‌سازی نصب قبلی کامل شد."
echo ""

# ============================================================
# مرحله 1: آپدیت سیستم و نصب پیش‌نیازها
# ============================================================
print_title "مرحله 1: نصب پیش‌نیازهای سیستم"

apt update
apt upgrade -y
apt install -y python3 python3-pip python3-venv curl jq wget ca-certificates dnsutils iputils-ping

print_success "پیش‌نیازهای سیستم نصب شدند."

# ============================================================
# مرحله 2: نصب و فعال‌سازی Docker
# ============================================================
print_title "مرحله 2: نصب Docker"

apt install -y docker.io
systemctl start docker
systemctl enable docker

print_success "Docker نصب و فعال شد."

# ============================================================
# مرحله 3: ساخت مسیر ربات و محیط مجازی پایتون
# ============================================================
print_title "مرحله 3: ساخت محیط اجرای ربات"

mkdir -p "$BOT_DIR"
mkdir -p "$VENV_DIR"

python3 -m venv "$VENV_DIR"

# فعال‌سازی محیط مجازی پایتون
source "$VENV_DIR/bin/activate"

print_success "محیط مجازی پایتون ساخته شد."

# ============================================================
# مرحله 4: دانلود فایل‌های ربات از GitHub
# ============================================================
print_title "مرحله 4: دانلود فایل‌های ربات"

cd "$BOT_DIR"

wget -q -O outline_bot.py "$REPO_BASE_URL/outline_bot.py"
wget -q -O delete_user.py "$REPO_BASE_URL/delete_user.py"
wget -q -O users_data.json "$REPO_BASE_URL/users_data.json"
wget -q -O update.sh "$REPO_BASE_URL/update.sh"
wget -q -O README.md "$REPO_BASE_URL/README.md"
wget -q -O version.txt "$REPO_BASE_URL/version.txt"
wget -q -O install.sh "$REPO_BASE_URL/install.sh"

# ------------------------------------------------------------
# بررسی فایل‌های ضروری
# ------------------------------------------------------------
if [ ! -f "outline_bot.py" ] || [ ! -f "delete_user.py" ] || [ ! -f "users_data.json" ] || [ ! -f "update.sh" ]; then
    print_error "خطا در دانلود فایل‌های ربات. لطفاً اتصال اینترنت یا آدرس GitHub را بررسی کنید."
    exit 1
fi

chmod +x "$BOT_DIR"/*.py
chmod +x "$BOT_DIR/update.sh"

print_success "فایل‌های ربات دانلود و آماده شدند."

# ============================================================
# مرحله 5: نصب Outline Server
# ============================================================
print_title "مرحله 5: نصب Outline Server"

echo "در حال نصب سرور Outline..."
bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)"

if [ $? -eq 0 ]; then
    print_success "سرور Outline با موفقیت نصب شد."
else
    print_error "خطا در نصب سرور Outline."
    exit 1
fi

# ============================================================
# مرحله 6: بررسی فایل access.txt
# ============================================================
print_title "مرحله 6: خواندن اطلاعات Outline"

if [ ! -f "$ACCESS_FILE" ]; then
    print_error "فایل $ACCESS_FILE پیدا نشد."
    echo "نصب Outline کامل نشده یا مسیر فایل تغییر کرده است."
    exit 1
fi

# ------------------------------------------------------------
# استخراج apiUrl و certSha256 از access.txt
# دو مدل خروجی پشتیبانی می‌شود:
# 1. JSON:
#    {"apiUrl":"https://IP:PORT/API_KEY","certSha256":"HASH"}
# 2. متن معمولی شامل apiUrl و certSha256
# ------------------------------------------------------------
ACCESS_JSON=$(grep -o '{.*}' "$ACCESS_FILE" | tail -n 1 || true)

if [ -n "$ACCESS_JSON" ]; then
    ORIGINAL_OUTLINE_API_URL=$(echo "$ACCESS_JSON" | jq -r '.apiUrl')
    CERT_SHA256=$(echo "$ACCESS_JSON" | jq -r '.certSha256')
else
    ORIGINAL_OUTLINE_API_URL=$(grep -oP 'https://[^"]+' "$ACCESS_FILE" | head -n 1 || true)
    CERT_SHA256=$(grep -oP 'certSha256[^A-Fa-f0-9]*\K[A-Fa-f0-9]{64}' "$ACCESS_FILE" | head -n 1 || true)
fi

if [ -z "${ORIGINAL_OUTLINE_API_URL:-}" ] || [ "$ORIGINAL_OUTLINE_API_URL" = "null" ]; then
    print_error "apiUrl از فایل access.txt استخراج نشد."
    echo "محتوای فایل:"
    cat "$ACCESS_FILE"
    exit 1
fi

if [ -z "${CERT_SHA256:-}" ] || [ "$CERT_SHA256" = "null" ]; then
    print_error "certSha256 از فایل access.txt استخراج نشد."
    echo "محتوای فایل:"
    cat "$ACCESS_FILE"
    exit 1
fi

# ------------------------------------------------------------
# استخراج API Key از انتهای apiUrl
# مثال:
# https://185.204.168.242:51711/JIhHaWuqr_WXwb0_vxAYcw
# خروجی:
# JIhHaWuqr_WXwb0_vxAYcw
# ------------------------------------------------------------
OUTLINE_API_KEY=$(echo "$ORIGINAL_OUTLINE_API_URL" | awk -F'/' '{print $NF}')

if [ -z "$OUTLINE_API_KEY" ]; then
    print_error "OUTLINE_API_KEY از apiUrl استخراج نشد."
    exit 1
fi

print_success "اطلاعات اولیه Outline استخراج شد."
echo "apiUrl اصلی:"
echo "$ORIGINAL_OUTLINE_API_URL"
echo ""
echo "certSha256:"
echo "$CERT_SHA256"
echo ""

# ============================================================
# مرحله 7: دریافت دامین یا استفاده از IP
# ============================================================
print_title "مرحله 7: تنظیم آدرس مدیریت Outline"

echo "در این مرحله مشخص می‌کنیم ربات با IP به Outline وصل شود یا با دامین."
echo ""
echo "اگر دامین دارید، باید A Record دامین به IP همین سرور اشاره کند."
echo "اگر دامین ندارید، گزینه n را وارد کنید تا IP سرور استفاده شود."
echo ""

while true; do
    read -rp "آیا دامین دارید؟ (y/n): " HAS_DOMAIN
    HAS_DOMAIN=$(echo "$HAS_DOMAIN" | tr -d ' ')

    if [[ "$HAS_DOMAIN" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]; then
        while true; do
            read -rp "لطفاً دامین خود را بدون https وارد کنید، مثال: noora.iritjob.ir : " DOMAIN_NAME
            DOMAIN_NAME=$(echo "$DOMAIN_NAME" | sed 's#https://##g' | sed 's#http://##g' | tr -d ' ')

            if [[ "$DOMAIN_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                print_error "فرمت دامین معتبر نیست. دوباره وارد کنید."
            fi
        done

        DOMAIN_IP=$(dig +short A "$DOMAIN_NAME" | tail -n 1 || true)
        SERVER_IP=$(curl -4 -s icanhazip.com || curl -4 -s ifconfig.me || true)

        if [ -z "$DOMAIN_IP" ]; then
            print_error "IP دامین پیدا نشد. DNS دامین را بررسی کنید."
            exit 1
        fi

        if [ -z "$SERVER_IP" ]; then
            print_error "IP سرور استخراج نشد. اتصال اینترنت سرور را بررسی کنید."
            exit 1
        fi

        if [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
            print_success "دامین با IP سرور هماهنگ است."

            # ------------------------------------------------
            # حفظ پورت و API Key از apiUrl اصلی Outline
            # فقط هاست/IP با دامین جایگزین می‌شود.
            # ------------------------------------------------
            OUTLINE_PORT=$(echo "$ORIGINAL_OUTLINE_API_URL" | sed -E 's#^https?://[^:/]+:([0-9]+)/.*#\1#')
            OUTLINE_PATH=$(echo "$ORIGINAL_OUTLINE_API_URL" | sed -E 's#^https?://[^/]+(/.*)$#\1#')

            OUTLINE_API_URL="https://$DOMAIN_NAME:$OUTLINE_PORT$OUTLINE_PATH"
            break
        else
            print_error "دامین وارد شده با IP سرور هماهنگ نیست."
            echo "دامین وارد شده: $DOMAIN_NAME"
            echo "IP دامین: $DOMAIN_IP"
            echo "IP سرور: $SERVER_IP"
            echo ""
            echo "اول DNS دامین را درست کنید، بعد دوباره نصب را اجرا کنید."
            exit 1
        fi

    elif [[ "$HAS_DOMAIN" =~ ^[Nn]$|^[Nn][Oo]$ ]]; then
        OUTLINE_API_URL="$ORIGINAL_OUTLINE_API_URL"
        print_success "دامین ثبت نشد؛ آدرس اصلی Outline با IP استفاده می‌شود."
        break

    else
        print_error "لطفاً فقط y یا n وارد کنید."
    fi
done

# ------------------------------------------------------------
# بررسی نهایی اطلاعات Outline
# ------------------------------------------------------------
if [ -z "$OUTLINE_API_URL" ] || [ -z "$OUTLINE_API_KEY" ] || [ -z "$CERT_SHA256" ]; then
    print_error "اطلاعات Outline کامل نیست."
    exit 1
fi

echo ""
echo "اطلاعات نهایی Outline:"
echo "OUTLINE_API_URL: $OUTLINE_API_URL"
echo "OUTLINE_API_KEY: $OUTLINE_API_KEY"
echo "CERT_SHA256: $CERT_SHA256"
echo ""

# ============================================================
# مرحله 8: ویزارد تنظیمات ربات تلگرام
# ============================================================
print_title "مرحله 8: ویزارد تنظیمات ربات تلگرام"

echo "در این مرحله اطلاعات ربات تلگرام دریافت می‌شود."
echo "اگر هنوز ربات نساخته‌اید، از BotFather در تلگرام ربات بسازید."
echo ""

# ------------------------------------------------------------
# دریافت توکن ربات تلگرام
# ------------------------------------------------------------
while true; do
    echo "------------------------------------------------------------"
    echo "مرحله 1 از 3: وارد کردن توکن ربات تلگرام"
    echo "------------------------------------------------------------"
    echo "نمونه فرمت توکن:"
    echo "123456789:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo ""

    read -rp "لطفاً توکن ربات تلگرام را وارد کنید: " BOT_TOKEN
    BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d ' ')

    if [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        print_success "توکن ربات دریافت شد."
        break
    else
        print_error "فرمت توکن اشتباه است."
        echo "توکن را دقیقاً از BotFather کپی کنید."
        echo ""
    fi
done

# ------------------------------------------------------------
# دریافت آیدی عددی مدیران
# ------------------------------------------------------------
ADMIN_IDS=()

echo ""
echo "------------------------------------------------------------"
echo "مرحله 2 از 3: وارد کردن آیدی عددی مدیران"
echo "------------------------------------------------------------"
echo "فقط این آیدی‌ها اجازه استفاده از ربات را خواهند داشت."
echo "برای گرفتن آیدی عددی می‌توانید از @userinfobot استفاده کنید."
echo "بعد از وارد کردن همه مدیرها، n را وارد کنید."
echo ""

while true; do
    read -rp "آیدی عددی مدیر را وارد کنید یا برای پایان n بزنید: " ADMIN_ID
    ADMIN_ID=$(echo "$ADMIN_ID" | tr -d ' ')

    if [[ "$ADMIN_ID" =~ ^[Nn]$ ]]; then
        if [ ${#ADMIN_IDS[@]} -eq 0 ]; then
            print_error "حداقل باید یک مدیر وارد شود."
            continue
        fi
        break
    fi

    if [[ ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        print_error "آیدی مدیر باید فقط عدد باشد."
        continue
    fi

    ADMIN_IDS+=("$ADMIN_ID")
    print_success "مدیر با آیدی $ADMIN_ID اضافه شد."
done

ADMIN_IDS_STR=$(printf "%s, " "${ADMIN_IDS[@]}" | sed 's/, $//')
ADMIN_IDS_STR="[${ADMIN_IDS_STR}]"

echo ""
print_success "لیست مدیران ثبت شد: $ADMIN_IDS_STR"

# ------------------------------------------------------------
# دریافت کانال بکاپ خودکار
# ------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo "مرحله 3 از 3: تنظیم کانال بکاپ خودکار"
echo "------------------------------------------------------------"
echo "ربات فایل‌های بکاپ را داخل این کانال ارسال می‌کند."
echo "حتماً ربات را داخل کانال ادمین کنید."
echo ""
echo "فرمت کانال عمومی:"
echo "@channel_username"
echo ""
echo "فرمت کانال خصوصی:"
echo "https://t.me/+xxxxxxxx"
echo ""

while true; do
    read -rp "لینک یا یوزرنیم کانال بکاپ را وارد کنید: " BACKUP_CHANNEL
    BACKUP_CHANNEL=$(echo "$BACKUP_CHANNEL" | tr -d ' ')

    if [[ "$BACKUP_CHANNEL" =~ ^@([a-zA-Z0-9_]{5,32})$ ]]; then
        print_success "کانال عمومی تایید شد: $BACKUP_CHANNEL"
        BACKUP_CHANNEL_ID="null"
        break

    elif [[ "$BACKUP_CHANNEL" =~ ^https://t.me/\+[a-zA-Z0-9_-]+$ ]]; then
        print_success "لینک کانال خصوصی تایید شد: $BACKUP_CHANNEL"
        echo ""
        echo "برای کانال خصوصی باید آیدی عددی کانال را هم وارد کنید."
        echo "نمونه:"
        echo "-1001234567890"
        echo ""

        while true; do
            read -rp "آیدی عددی کانال خصوصی را وارد کنید: " BACKUP_CHANNEL_ID
            BACKUP_CHANNEL_ID=$(echo "$BACKUP_CHANNEL_ID" | tr -d ' ')

            if [[ "$BACKUP_CHANNEL_ID" =~ ^-100[0-9]{9,15}$ ]]; then
                print_success "آیدی عددی کانال تایید شد: $BACKUP_CHANNEL_ID"
                break
            else
                print_error "آیدی کانال خصوصی معتبر نیست."
                echo "باید با -100 شروع شود. مثال: -1001234567890"
            fi
        done

        break
    else
        print_error "فرمت کانال اشتباه است."
        echo "برای کانال عمومی مثل @channel_username وارد کنید."
        echo "برای کانال خصوصی مثل https://t.me/+xxxxxxxx وارد کنید."
        echo ""
    fi
done

print_success "اطلاعات ربات با موفقیت دریافت شد."

# ============================================================
# مرحله 9: ساخت فایل تنظیمات .config.json
# ============================================================
print_title "مرحله 9: ساخت فایل تنظیمات ربات"

# ------------------------------------------------------------
# BACKUP_CHANNEL_ID اگر null باشد به صورت JSON null ذخیره می‌شود.
# اگر عدد کانال خصوصی باشد به صورت رشته ذخیره می‌شود.
# ------------------------------------------------------------
if [ "$BACKUP_CHANNEL_ID" = "null" ]; then
    BACKUP_CHANNEL_ID_JSON="null"
else
    BACKUP_CHANNEL_ID_JSON="\"$BACKUP_CHANNEL_ID\""
fi

cat > "$CONFIG_FILE" <<EOF
{
    "OUTLINE_API_URL": "$OUTLINE_API_URL",
    "OUTLINE_API_KEY": "$OUTLINE_API_KEY",
    "CERT_SHA256": "$CERT_SHA256",
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_IDS": $ADMIN_IDS_STR,
    "BACKUP_CHANNEL": "$BACKUP_CHANNEL",
    "BACKUP_CHANNEL_ID": $BACKUP_CHANNEL_ID_JSON
}
EOF

chmod 600 "$CONFIG_FILE"

# بررسی معتبر بودن JSON
if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    print_error "فایل .config.json معتبر ساخته نشد."
    cat "$CONFIG_FILE"
    exit 1
fi

print_success "فایل تنظیمات ساخته شد: $CONFIG_FILE"

# ============================================================
# مرحله 10: ارسال پیام نصب موفق به مدیر اول
# ============================================================
print_title "مرحله 10: ارسال پیام نصب موفق در تلگرام"

FIRST_ADMIN_ID="${ADMIN_IDS[0]}"

WELCOME_TEXT=$(cat <<EOF
🚀 نصب سرور با موفقیت انجام شد.

نسخه فعلی: 1.37.3

********

API URL from Outline Server:

{"apiUrl":"$OUTLINE_API_URL","certSha256":"$CERT_SHA256"}

🚀 لطفاً مقادیر بالا را در Outline Manager وارد کنید تا به سرور متصل شوید.

🡇 لینک دانلود همه سیستم‌عامل‌ها برای مدیریت سرور و کاربران 🡇

**********
📥 لینک دانلود ویندوز:
https://s3.amazonaws.com/outline-releases/manager/windows/stable/Outline-Manager.exe

*******
📥 لینک دانلود مک:
https://s3.amazonaws.com/outline-releases/manager/macos/stable/Outline-Manager.dmg

*******
📥 لینک دانلود لینوکس:
https://s3.amazonaws.com/outline-releases/manager/linux/stable/Outline-Manager.AppImage

*******

📂 لطفاً اطمینان حاصل کنید که ربات در کانال بکاپ به عنوان ادمین اضافه شده است تا بتواند بکاپ‌ها را ارسال کند.

آیدی پشتیبانی 24 ساعته:
@irannetwork_co
EOF
)

SEND_RESULT=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$FIRST_ADMIN_ID" \
    --data-urlencode "text=$WELCOME_TEXT")

if echo "$SEND_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    print_success "پیام نصب موفق به مدیر اول ارسال شد."
else
    print_warning "پیام تلگرام ارسال نشد. احتمالاً توکن، آیدی مدیر یا دسترسی ربات مشکل دارد."
    echo "پاسخ تلگرام:"
    echo "$SEND_RESULT"
fi

# ============================================================
# مرحله 11: نصب کتابخانه‌های پایتون موردنیاز
# ============================================================
print_title "مرحله 11: نصب کتابخانه‌های پایتون"

source "$VENV_DIR/bin/activate"

pip install --upgrade pip
pip install requests python-telegram-bot pytz
pip install "python-telegram-bot[job-queue]"

print_success "کتابخانه‌های پایتون نصب شدند."

# ============================================================
# مرحله 12: ساخت فایل‌ها و مسیرهای لازم
# ============================================================
print_title "مرحله 12: آماده‌سازی فایل‌ها و لاگ‌ها"

mkdir -p "$BOT_DIR/logs"
touch "$BOT_DIR/logs/bot.log"
touch "$BOT_DIR/service.log"

if [ ! -f "$BOT_DIR/users_data.json" ]; then
    echo '{"next_id": 1, "users": {}}' > "$BOT_DIR/users_data.json"
fi

chmod 600 "$BOT_DIR/users_data.json"
chmod 644 "$BOT_DIR/logs/bot.log"
chmod 644 "$BOT_DIR/service.log"

print_success "فایل‌ها و مسیرهای لازم آماده شدند."

# ============================================================
# مرحله 13: تنظیم Cron برای حذف کاربران منقضی‌شده
# ============================================================
print_title "مرحله 13: تنظیم Cron حذف کاربران منقضی‌شده"

CRON_COMMAND="0 0 * * * $VENV_DIR/bin/python3 $BOT_DIR/delete_user.py"

# جلوگیری از ثبت تکراری cron job
(crontab -l 2>/dev/null | grep -v "$BOT_DIR/delete_user.py" || true; echo "$CRON_COMMAND") | crontab -

print_success "Cron حذف کاربران منقضی‌شده تنظیم شد."

# ============================================================
# مرحله 14: ساخت سرویس systemd
# ============================================================
print_title "مرحله 14: ساخت سرویس اجرای خودکار ربات"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Outline Bot Service
After=network.target docker.service
Wants=docker.service

[Service]
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$VENV_DIR/bin/python3 $BOT_DIR/outline_bot.py
Restart=always
RestartSec=5
TimeoutStopSec=10
StandardOutput=append:$BOT_DIR/service.log
StandardError=append:$BOT_DIR/service.log

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

print_success "سرویس systemd ساخته شد."

# ============================================================
# مرحله 15: تنظیم تایم‌زون و اجرای سرویس
# ============================================================
print_title "مرحله 15: فعال‌سازی و اجرای ربات"

timedatectl set-timezone Asia/Tehran || print_warning "تنظیم تایم‌زون انجام نشد، ولی نصب ادامه پیدا می‌کند."

systemctl daemon-reload
systemctl enable outline_bot.service
systemctl restart outline_bot.service

sleep 2

if systemctl is-active --quiet outline_bot.service; then
    print_success "ربات با موفقیت اجرا شد."
else
    print_error "سرویس ربات اجرا نشد."
    echo ""
    echo "برای دیدن خطا این دستور را بزنید:"
    echo "journalctl -u outline_bot.service -n 100 --no-pager"
    echo ""
    echo "یا لاگ فایل را ببینید:"
    echo "cat $BOT_DIR/service.log"
    exit 1
fi

# ============================================================
# پایان نصب
# ============================================================
print_title "نصب کامل شد"

echo "نصب و راه‌اندازی ربات و سرور Outline کامل شد."
echo ""
echo "اطلاعات مدیریت Outline:"
echo "{\"apiUrl\":\"$OUTLINE_API_URL\",\"certSha256\":\"$CERT_SHA256\"}"
echo ""
echo "مسیر فایل تنظیمات:"
echo "$CONFIG_FILE"
echo ""
echo "وضعیت سرویس:"
systemctl status outline_bot.service --no-pager -l
