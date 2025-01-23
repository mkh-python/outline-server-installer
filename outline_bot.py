import logging
from telegram import InlineKeyboardMarkup, InlineKeyboardButton
from telegram.ext import MessageHandler, filters
from telegram.ext import CallbackQueryHandler
import signal
import asyncio


import requests
import subprocess
import urllib3
from threading import Timer
import json
from pytz import timezone
from datetime import datetime, timedelta
from telegram import Update, ReplyKeyboardMarkup
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    CallbackContext,
    ConversationHandler,
    filters,
)
import os
import sys
import zipfile


LOCK_FILE = "/tmp/outline_bot.lock"

# بررسی وجود فایل قفل (تنها در صورت نیاز)
USE_LOCK_FILE = False  # تنظیم به True در صورت نیاز به استفاده از فایل قفل

if USE_LOCK_FILE and os.path.exists(LOCK_FILE):
    print("ربات در حال حاضر در حال اجرا است. فرآیند متوقف می‌شود.")
    sys.exit(1)

if USE_LOCK_FILE:
    # ایجاد فایل قفل
    with open(LOCK_FILE, "w") as lock:
        lock.write(str(os.getpid()))

# حذف فایل قفل هنگام خروج (تنها در صورت استفاده)
if USE_LOCK_FILE:
    import atexit
    def remove_lock():
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)

    atexit.register(remove_lock)



urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# مسیر فایل تنظیمات
CONFIG_PATH = "/opt/outline_bot/.config.json"

# بارگذاری تنظیمات از فایل
def load_config():
    try:
        with open(CONFIG_PATH, "r") as file:
            return json.load(file)
    except FileNotFoundError:
        raise Exception(f"فایل تنظیمات یافت نشد: {CONFIG_PATH}")
    except json.JSONDecodeError:
        raise Exception("خطا در خواندن فایل تنظیمات JSON.")

# بارگذاری تنظیمات
config = load_config()

# متغیرهای تنظیمات
BOT_TOKEN = config["BOT_TOKEN"]
ADMIN_IDS = config["ADMIN_IDS"]
OUTLINE_API_URL = config["OUTLINE_API_URL"]
OUTLINE_API_KEY = config["OUTLINE_API_KEY"]
CERT_SHA256 = config["CERT_SHA256"]
DATA_FILE = "/opt/outline_bot/users_data.json"  # مسیر فایل ذخیره اطلاعات کاربران

# تنظیمات لاگ
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# مراحل گفتگو
GET_USER_NAME = 1
GET_SUBSCRIPTION_DURATION = 2
GET_USER_ID = 3
GET_DATA_LIMIT = 4

BOT_VERSION = "1.37.3"

MAIN_KEYBOARD = ReplyKeyboardMarkup(
    [
        ["🆕 ایجاد کاربر", "👥 مشاهده کاربران"],
        ["❌ حذف کاربر", "💬 درخواست پشتیبانی"],
        ["🔄 دریافت آخرین آپدیت", "🎯 دریافت اکانت تست"],
        ["📂 پشتیبان‌گیری"]
    ],
    resize_keyboard=True,
)

# منوی پشتیبان‌گیری
BACKUP_MENU_KEYBOARD = ReplyKeyboardMarkup(
    [
        ["📥 بکاپ", "📤 ریستور"],  # دکمه‌های بکاپ و ریستور
        ["🔙 بازگشت"]  # دکمه بازگشت
    ],
    resize_keyboard=True
)


# تابع برای نمایش منوی پشتیبان‌گیری
async def show_backup_menu(update, context):
    await update.message.reply_text(
        "لطفاً یکی از گزینه‌های زیر را انتخاب کنید:",
        reply_markup=BACKUP_MENU_KEYBOARD
    )

async def backup_files(update, context):
    backup_path = "/opt/outline_bot/backup_restore/backup_file"
    os.makedirs(backup_path, exist_ok=True)

    # فایل‌هایی که باید بکاپ گرفته شوند
    files_to_backup = [
        "/opt/outline_bot/users_data.json",
        "/opt/outline/persisted-state/shadowbox_config.json",
        "/opt/outline/persisted-state/outline-ss-server/config.yml"
    ]

    # نام فایل ZIP
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    backup_file = os.path.join(backup_path, f"backup_{timestamp}.zip")

    try:
        # فشرده‌سازی فایل‌ها
        with zipfile.ZipFile(backup_file, "w") as zipf:
            for file_path in files_to_backup:
                if os.path.exists(file_path):
                    zipf.write(file_path, os.path.basename(file_path))
                    backup_logger.info(f"File {file_path} added to backup.")
                else:
                    backup_logger.warning(f"File {file_path} does not exist.")

        await update.message.reply_text("بکاپ با موفقیت ایجاد شد!")
        backup_logger.info(f"Backup created successfully at {backup_file}")

        # ارسال فایل بکاپ به تلگرام
        with open(backup_file, "rb") as f:
            await context.bot.send_document(
                chat_id=update.effective_chat.id,
                document=f,
                filename=f"backup_{timestamp}.zip",
                caption="📂 فایل بکاپ ایجاد شده و در اینجا ارسال می‌شود."
            )
    except Exception as e:
        await update.message.reply_text("خطایی در ایجاد بکاپ رخ داد!")
        backup_logger.error(f"Error creating backup: {str(e)}")



async def restore_files(update, context):
    backup_path = "/opt/outline_bot/backup_restore/backup_file"
    os.makedirs(backup_path, exist_ok=True)

    # لیست فایل‌های بکاپ
    backup_files = os.listdir(backup_path)
    backup_files.sort(key=lambda x: datetime.strptime(x, "backup_%Y-%m-%d_%H-%M-%S.zip"), reverse=False)

    # ایجاد دکمه‌های اینلاین
    keyboard = []

    if backup_files:
        # دکمه‌ها برای فایل‌های موجود
        keyboard.extend([[InlineKeyboardButton(file, callback_data=f"restore_{file}")] for file in backup_files])
    else:
        # پیام برای زمانی که هیچ بکاپی وجود ندارد
        await update.message.reply_text("❌ هیچ بکاپی در سرور ندارد.")
    
    # دکمه ارسال فایل از سیستم همیشه اضافه می‌شود
    keyboard.append([InlineKeyboardButton("ارسال فایل از سیستم", callback_data="upload_backup")])

    # نمایش دکمه‌ها
    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("لطفاً یک فایل برای ریستور انتخاب کنید:", reply_markup=reply_markup)
    backup_logger.info(f"Available backups listed for restore: {backup_files}")

async def prompt_upload_backup(update: Update, context: CallbackContext):
    try:
        # ارسال پیام برای آپلود فایل
        await update.callback_query.message.reply_text(
            "📤 لطفاً فایل بکاپ خود را ارسال کنید. فایل باید فرمت ZIP داشته باشد.\n"
            "⏬ منتظر بارگذاری فایل شما هستیم...",
        )
    except Exception as e:
        backup_logger.error(f"Error prompting for backup upload: {str(e)}")

async def handle_uploaded_backup(update, context):
    try:
        # بررسی وجود پیام و فایل
        if not update.message or not update.message.document:
            await update.message.reply_text("فایل معتبری ارسال نشده است.")
            return

        # دریافت فایل از پیام
        file = update.message.document
        if not file.file_name.endswith(".zip"):
            await update.message.reply_text("فایل ارسالی باید با فرمت ZIP باشد.")
            return

        # دریافت فایل از تلگرام
        tg_file = await file.get_file()

        # مسیر ذخیره‌سازی فایل
        restore_path = "/opt/outline_bot/backup_restore/restore_file"
        os.makedirs(restore_path, exist_ok=True)
        file_path = os.path.join(restore_path, file.file_name)

        # دانلود فایل و ذخیره آن
        await tg_file.download_to_drive(file_path)
        await update.message.reply_text("✅ فایل با موفقیت دریافت شد. در حال ریستور بکاپ هستیم...")

        # ریستور فایل آپلودشده
        await restore_selected_file(file.file_name, update, from_user_upload=True)

    except Exception as e:
        await update.message.reply_text("❌ خطا در دریافت و ریستور فایل بکاپ!")
        backup_logger.error(f"Error handling uploaded backup: {str(e)}")



async def back_to_main(update, context):
    await update.message.reply_text("بازگشت به منوی اصلی:", reply_markup=MAIN_KEYBOARD)

async def handle_restore_callback(update, context):
    query = update.callback_query
    await query.answer()

    # استخراج داده از callback_data
    callback_data = query.data
    if callback_data.startswith("restore_"):
        # عملیات ریستور فایل انتخاب‌شده از لیست
        file_name = callback_data.replace("restore_", "")
        await restore_selected_file(file_name, update, from_user_upload=False)
    elif callback_data == "upload_backup":
        # راه‌اندازی ارسال فایل توسط کاربر
        await prompt_upload_backup(update, context)


async def restore_selected_file(file_name, update, from_user_upload=False):
    try:
        # تعیین مسیر بر اساس نوع درخواست
        if from_user_upload:
            restore_path = "/opt/outline_bot/backup_restore/restore_file"
        else:
            restore_path = "/opt/outline_bot/backup_restore/backup_file"

        backup_file_path = os.path.join(restore_path, file_name)

        # بررسی وجود فایل بکاپ
        if not os.path.exists(backup_file_path):
            if update.callback_query and update.callback_query.message:
                await update.callback_query.message.reply_text(f"فایل بکاپ {file_name} یافت نشد.")
            else:
                raise ValueError("هیچ پیام یا callback_query معتبری موجود نیست.")
            return

        # مسیر فایل‌های اصلی
        target_paths = {
            "users_data.json": "/opt/outline_bot/users_data.json",
            "shadowbox_config.json": "/opt/outline/persisted-state/shadowbox_config.json",
            "config.yml": "/opt/outline/persisted-state/outline-ss-server/config.yml",
        }

        # استخراج فایل‌ها
        with zipfile.ZipFile(backup_file_path, 'r') as zip_ref:
            zip_ref.extractall(restore_path)

        # انتقال فایل‌ها به مسیرهای اصلی
        for extracted_file in zip_ref.namelist():
            if extracted_file in target_paths:
                source = os.path.join(restore_path, extracted_file)
                destination = target_paths[extracted_file]
                os.replace(source, destination)

        # پیام موفقیت ریستور
        if update.message:
            await update.message.reply_text(f"ریستور فایل {file_name} با موفقیت انجام شد!")
        elif update.callback_query and update.callback_query.message:
            await update.callback_query.message.reply_text(f"ریستور فایل {file_name} با موفقیت انجام شد!")
        else:
            backup_logger.error("هیچ پیام یا callback_query معتبری برای ارسال پیام موفقیت موجود نیست.")

        # ریستارت سرویس‌ها
        await update.callback_query.message.reply_text("♻️ در حال ریستارت سرویس‌ها، لطفاً منتظر بمانید...")
        try:
            subprocess.run(["docker", "start", "shadowbox"], check=True)
            subprocess.run(["docker", "start", "watchtower"], check=True)
            subprocess.run(["sudo", "systemctl", "restart", "outline_bot.service"], check=True)
            await update.callback_query.message.reply_text("✅ سرویس‌ها با موفقیت ریستارت شدند!")
            backup_logger.info("Services restarted successfully.")
        except subprocess.CalledProcessError as e:
            await update.callback_query.message.reply_text("❌ خطا در ریستارت سرویس‌ها!")
            backup_logger.error(f"Error restarting services: {str(e)}")

    except Exception as e:
        # مدیریت خطا
        if update.callback_query and update.callback_query.message:
            await update.callback_query.message.reply_text("خطا در فرآیند ریستور.")
        backup_logger.error(f"Error restoring file {file_name}: {str(e)}")


def graceful_shutdown(*args):
    logger.info("Shutting down gracefully...")
    sys.exit(0)

signal.signal(signal.SIGTERM, graceful_shutdown)
signal.signal(signal.SIGINT, graceful_shutdown)



# تنظیمات مسیر لاگ
log_dir = "/opt/outline_bot/logs"
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, "backup_restore.log")


# غیرفعال کردن لاگ‌های عمومی
logging.basicConfig(
    level=logging.CRITICAL  # تنها لاگ‌های بحرانی نمایش داده شوند
)

# تنظیمات لاگ اختصاصی برای پشتیبان‌گیری
backup_logger = logging.getLogger("backup_restore")
backup_logger.setLevel(logging.DEBUG)

# افزودن خروجی کنسول برای لاگ‌های پشتیبان‌گیری
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.DEBUG)
console_formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
console_handler.setFormatter(console_formatter)

backup_logger.addHandler(console_handler)


# هندلر دریافت اکانت تست
async def create_test_account(update: Update, context: CallbackContext):
    user = update.effective_user
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این بخش نیستید.")
        return

    test_user_name = f"Test-{user.id}"
    expiry_date = datetime.now() + timedelta(hours=1)  # تنظیم به 1 ساعت
    data_limit_gb = 1  # محدودیت حجم 1 گیگابایت

    try:
        # ایجاد کاربر تست در Outline
        response = requests.post(
            f"{OUTLINE_API_URL}/access-keys",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            json={"name": test_user_name},
            verify=False,
        )

        if response.status_code in [200, 201]:
            data = response.json()
            user_id = data["id"]
            access_url = data["accessUrl"]

            # اعمال محدودیت حجمی
            limit_bytes = data_limit_gb * 1024**3  # تبدیل گیگابایت به بایت
            limit_response = requests.put(
                f"{OUTLINE_API_URL}/access-keys/{user_id}/data-limit",
                headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                json={"limit": {"bytes": limit_bytes}},
                verify=False,
            )

            if limit_response.status_code == 204:
                logger.info(f"محدودیت حجمی {data_limit_gb} گیگابایت با موفقیت اعمال شد.")
            else:
                logger.warning(f"خطا در اعمال محدودیت حجمی: {limit_response.status_code} {limit_response.text}")

            # ذخیره اطلاعات کاربر تست در فایل JSON
            user_data = load_user_data()
            user_data["users"][str(user_id)] = {
                "name": test_user_name,
                "expiry_date": expiry_date.strftime("%Y-%m-%d %H:%M:%S"),
                "accessUrl": access_url,
                "data_limit_gb": data_limit_gb,
            }
            save_user_data(user_data)

            # ارسال پیام موفقیت
            message = (
                f"اکانت تست با موفقیت ایجاد شد! 🎉\n\n"
                f"Name: {test_user_name}\n"
                f"زمان انقضا: {expiry_date.strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"حجم مصرفی مجاز: {data_limit_gb} گیگابایت\n\n"
                f"لینک اتصال:\n{access_url}"
            )
            await update.message.reply_text(message)
        else:
            logger.error(f"خطا در ایجاد اکانت تست: {response.status_code} {response.text}")
            await update.message.reply_text("خطا در ایجاد اکانت تست!")
    except Exception as e:
        logger.error(f"Exception in create_test_account: {str(e)}")
        await update.message.reply_text("خطای غیرمنتظره در ایجاد اکانت تست!")

    await update.message.reply_text("به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)


async def ask_for_data_limit(update: Update, context: CallbackContext):
    duration_text = update.message.text
    if duration_text == "بازگشت":
        await update.message.reply_text("عملیات لغو شد. به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)
        return ConversationHandler.END

    if duration_text not in ["1 ماه", "2 ماه", "3 ماه"]:
        await update.message.reply_text("لطفاً یک گزینه معتبر انتخاب کنید.")
        return GET_SUBSCRIPTION_DURATION

    # ذخیره مدت زمان اشتراک
    duration_map = {"1 ماه": 1, "2 ماه": 2, "3 ماه": 3}
    context.user_data["subscription_months"] = duration_map[duration_text]

    await update.message.reply_text("لطفاً حجم مصرفی مجاز (بر حسب گیگابایت) را وارد کنید:")
    return GET_DATA_LIMIT

async def create_user_with_limit(update: Update, context: CallbackContext):
    try:
        data_limit_gb = update.message.text.strip()
        if not data_limit_gb.isdigit() or int(data_limit_gb) <= 0:
            await update.message.reply_text("لطفاً یک عدد معتبر وارد کنید.")
            return GET_DATA_LIMIT

        context.user_data["data_limit"] = int(data_limit_gb)
        user_name = context.user_data["user_name"]
        subscription_months = context.user_data["subscription_months"]
        expiry_date = datetime.now() + timedelta(days=30 * subscription_months)

        # ایجاد کاربر در Outline
        response = requests.post(
            f"{OUTLINE_API_URL}/access-keys",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            json={"name": user_name},
            verify=False,
        )

        if response.status_code in [200, 201]:
            data = response.json()
            user_id = data["id"]
            access_url = data["accessUrl"]

            # استخراج دامین از OUTLINE_API_URL
            domain_name = OUTLINE_API_URL.split("//")[1].split(":")[0]

            # جایگزینی دقیق دامین در لینک اتصال
            if "@" in access_url:
                parts = access_url.split("@")
                after_at = parts[1].split(":")
                after_at[0] = domain_name
                access_url = f"{parts[0]}@{':'.join(after_at)}"

            # تنظیم محدودیت حجمی
            limit_bytes = context.user_data["data_limit"] * 1024**3  # تبدیل گیگابایت به بایت
            limit_response = requests.put(
                f"{OUTLINE_API_URL}/access-keys/{user_id}/data-limit",
                headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                json={"limit": {"bytes": limit_bytes}},
                verify=False,
            )

            if limit_response.status_code == 204:
                logger.info(f"محدودیت حجمی {context.user_data['data_limit']} گیگابایت با موفقیت اعمال شد.")
            else:
                logger.warning(f"خطا در اعمال محدودیت حجمی: {limit_response.status_code} {limit_response.text}")

            # ذخیره اطلاعات کاربر
            user_data = load_user_data()
            user_data["users"][str(user_id)] = {
                "name": user_name,
                "expiry_date": expiry_date.strftime("%Y-%m-%d"),
                "accessUrl": access_url,
                "data_limit_gb": context.user_data["data_limit"],
            }
            save_user_data(user_data)

            # پیام موفقیت
            message = (
                f"کاربر جدید ایجاد شد! 🎉\n\n"
                f"نام: {user_name}\n"
                f"تاریخ انقضا: {expiry_date.strftime('%Y-%m-%d')}\n"
                f"حجم مصرفی مجاز: {context.user_data['data_limit']} گیگابایت\n\n"
                f"لینک اتصال:\n{access_url}"
            )
            await update.message.reply_text(message, reply_markup=MAIN_KEYBOARD)
        else:
            logger.error(f"خطا در ایجاد کاربر: {response.status_code} {response.text}")
            await update.message.reply_text("خطا در ایجاد کاربر!")
    except Exception as e:
        logger.error(f"Exception in create_user_with_limit: {str(e)}")
        await update.message.reply_text("خطای غیرمنتظره در ایجاد کاربر!")

    return ConversationHandler.END


def schedule_user_cleanup():
    remove_expired_users()
    Timer(60, schedule_user_cleanup).start()  # اجرای هر 60 ثانیه


# هندلر دریافت آخرین آپدیت
async def check_for_update(update: Update, context: CallbackContext):
    GITHUB_VERSION_URL = "https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/version.txt"
    LOCAL_VERSION_FILE = "/opt/outline_bot/version.txt"
    LOCAL_UPDATE_SCRIPT = "/opt/outline_bot/update.sh"

    try:
        # خواندن نسخه فعلی از فایل محلی
        try:
            with open(LOCAL_VERSION_FILE, "r") as file:
                current_version = file.read().strip()
        except FileNotFoundError:
            current_version = "unknown"

        # دریافت نسخه جدید از گیت‌هاب
        response = requests.get(GITHUB_VERSION_URL)
        if response.status_code == 200:
            latest_version = response.text.strip()

            # مقایسه نسخه فعلی با نسخه جدید
            if current_version == latest_version:
                await update.message.reply_text(
                    f"🎉 شما در حال استفاده از آخرین نسخه هستید: {current_version}"
                )
            else:
                await update.message.reply_text(
                    f"🔔 نسخه جدیدی در دسترس است: {latest_version}\n\n"
                    "✨ لطفاً صبور باشید، فرآیند به‌روزرسانی به زودی آغاز می‌شود..."
                )

                # اجرای فایل به‌روزرسانی
                process = subprocess.run(["sudo", "bash", LOCAL_UPDATE_SCRIPT], capture_output=True, text=True)

                if process.returncode == 0:
                    await update.message.reply_text(
                        f"🚀 به‌روزرسانی با موفقیت انجام شد! 🌟\n\n"
                        f"🔄 نسخه جدید ربات شما: {latest_version}\n"
                        "✨ ربات شما اکنون آماده استفاده است."
                    )
                else:
                    await update.message.reply_text(
                        "❌ خطا در فرآیند به‌روزرسانی. لطفاً لاگ‌ها را بررسی کنید یا به صورت دستی اقدام کنید."
                    )
        else:
            await update.message.reply_text(
                "⚠️ خطا در بررسی نسخه جدید. لطفاً بعداً دوباره تلاش کنید."
            )
    except Exception as e:
        await update.message.reply_text(
            f"❌ خطای غیرمنتظره در بررسی یا اجرای به‌روزرسانی: {e}"
        )


# دکمه‌های پشتیبانی
SUPPORT_BUTTON = InlineKeyboardMarkup(
    [
        [
            InlineKeyboardButton(
                "چت با پشتیبانی", url="https://t.me/irannetwork_co"
            )
        ]
    ]
)


# مدیریت اطلاعات کاربران
def load_user_data():
    try:
        with open(DATA_FILE, "r") as file:
            data = json.load(file)
            if "next_id" not in data:
                data["next_id"] = 1
            if "users" not in data:
                data["users"] = {}
            return data
    except FileNotFoundError:
        # ایجاد فایل با مقدار پیش‌فرض
        initial_data = {"next_id": 1, "users": {}}
        save_user_data(initial_data)
        return initial_data

def save_user_data(data):
    try:
        with open(DATA_FILE, "w") as file:
            json.dump(data, file, indent=4)
        logger.info("Users data saved successfully.")
    except Exception as e:
        logger.error(f"Error saving users data: {str(e)}")

# بررسی کاربران منقضی‌شده
def check_expired_users():
    user_data = load_user_data()["users"]
    now = datetime.now()

    expired_users = []
    for user_id, details in user_data.items():
        expiry_date_str = details["expiry_date"]

        try:
            # بررسی فرمت تاریخ
            if " " in expiry_date_str:  # اگر تاریخ شامل زمان باشد
                expiry_date = datetime.strptime(expiry_date_str, "%Y-%m-%d %H:%M:%S")
            else:  # در غیر این صورت، زمان پیش‌فرض اضافه شود
                expiry_date = datetime.strptime(expiry_date_str, "%Y-%m-%d").replace(
                    hour=23, minute=59, second=59
                )

            # بررسی تاریخ انقضا
            if expiry_date < now:
                expired_users.append(user_id)
        except ValueError as e:
            logger.error(f"خطای فرمت تاریخ برای کاربر {user_id}: {e}")

    return expired_users



def remove_expired_users():
    expired_users = check_expired_users()
    if expired_users:
        user_data = load_user_data()
        for user_id in expired_users:
            response = requests.delete(
                f"{OUTLINE_API_URL}/access-keys/{user_id}",
                headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                verify=False,
            )
            if response.status_code == 204:
                user_data["users"].pop(user_id, None)
                save_user_data(user_data)
                logger.info(f"کاربر منقضی‌شده با شناسه {user_id} حذف شد.")


# تابع بررسی دسترسی
def is_admin(update: Update) -> bool:
    return update.effective_user.id in ADMIN_IDS

# شروع ربات
async def start(update: Update, context: CallbackContext):
    user = update.effective_user
    if not is_admin(update):
        logger.warning(f"Unauthorized access attempt by {user.first_name} ({user.id})")
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return
    logger.info(f"User {user.first_name} ({user.id}) started the bot.")
    await update.message.reply_text(
        "سلام! برای مدیریت سرور Outline یکی از گزینه‌های زیر را انتخاب کنید.",
        reply_markup=MAIN_KEYBOARD,
    )

# مرحله 1: دریافت نام کاربر
async def ask_for_user_name(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return ConversationHandler.END
    await update.message.reply_text("لطفاً نام کاربر جدید را وارد کنید:")
    return GET_USER_NAME

# مرحله 2: دریافت مدت زمان اشتراک
async def ask_for_subscription_duration(update: Update, context: CallbackContext):
    user_name = update.message.text
    context.user_data["user_name"] = user_name

    # بررسی نام تکراری
    user_data = load_user_data()
    for details in user_data["users"].values():
        if details["name"] == user_name:
            await update.message.reply_text("این نام کاربری قبلاً ثبت شده است. لطفاً نام دیگری انتخاب کنید.")
            return ConversationHandler.END

    await update.message.reply_text(
        "لطفاً مدت زمان اشتراک را انتخاب کنید:\n1️⃣ یک ماه\n2️⃣ دو ماه\n3️⃣ سه ماه",
        reply_markup=ReplyKeyboardMarkup([["1 ماه", "2 ماه", "3 ماه"], ["بازگشت"]], resize_keyboard=True),
    )
    return GET_SUBSCRIPTION_DURATION

# تابع ایجاد کاربر
async def create_user(update: Update, context: CallbackContext):
    user = update.effective_user
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return ConversationHandler.END

    duration_text = update.message.text
    if duration_text == "بازگشت":
        await update.message.reply_text("عملیات لغو شد. به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)
        return ConversationHandler.END

    if duration_text not in ["1 ماه", "2 ماه", "3 ماه"]:
        await update.message.reply_text("لطفاً یک گزینه معتبر انتخاب کنید.")
        return GET_SUBSCRIPTION_DURATION

    # مدت زمان اشتراک
    duration_map = {"1 ماه": 1, "2 ماه": 2, "3 ماه": 3}
    months = duration_map[duration_text]
    expiry_date = datetime.now() + timedelta(days=30 * months)

    # نام کاربر
    user_name = context.user_data["user_name"]

    try:
        # ایجاد کاربر در Outline
        response = requests.post(
            f"{OUTLINE_API_URL}/access-keys",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            json={"name": user_name},  # اضافه کردن نام کاربر به درخواست
            verify=False,
        )

        if response.status_code in [200, 201]:
            data = response.json()
            user_id = data["id"]
            access_url = data["accessUrl"]

            # تنظیم محدودیت حجمی
            data_limit_gb = 10  # حجم مجاز به گیگابایت
            limit_bytes = data_limit_gb * 1024 ** 3
            limit_response = requests.put(
                f"{OUTLINE_API_URL}/access-keys/{user_id}/data-limit",
                headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                json={"limit": {"bytes": limit_bytes}},
                verify=False,
            )

            if limit_response.status_code == 204:
                logger.info(f"محدودیت حجمی {data_limit_gb} گیگابایت با موفقیت اعمال شد.")
            else:
                logger.warning(f"خطا در اعمال محدودیت حجمی: {limit_response.status_code} {limit_response.text}")

            # ذخیره اطلاعات کاربر در فایل JSON
            user_data = load_user_data()
            user_data["users"][str(user_id)] = {
                "name": user_name,
                "expiry_date": expiry_date.strftime("%Y-%m-%d %H:%M:%S"),
                "accessUrl": access_url,
                "data_limit_gb": data_limit_gb,
            }
            save_user_data(user_data)

            # پیام نهایی
            message = (
                f"کاربر جدید ایجاد شد! 🎉\n\n"
                f"ID: {user_id}\n"
                f"Name: {user_name}\n"
                f"زمان انقضا: {expiry_date.strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"حجم مصرفی مجاز: {data_limit_gb} گیگابایت\n\n"
                f"لینک اتصال:\n"
                f"{access_url}\n\n"
                f"لینک دانلود برنامه outline برای تمام سیستم عامل ها:\n"
                f"iOS: [App Store](https://apps.apple.com/us/app/outline-app/id1356177741)\n"
                f"Android: [Play Store](https://play.google.com/store/apps/details?id=org.outline.android.client&hl=en&pli=1)\n"
                f"Windows: [Download](https://s3.amazonaws.com/outline-releases/client/windows/stable/Outline-Client.exe)\n"
                f"Mac: [App Store](https://apps.apple.com/us/app/outline-secure-internet-access/id1356178125?mt=12)"
            )
            await update.message.reply_text(message, parse_mode="Markdown")
        else:
            logger.error(f"Error creating user: {response.status_code} {response.text}")
            await update.message.reply_text("خطا در ایجاد کاربر!")
    except Exception as e:
        logger.error(f"Exception in create_user: {str(e)}")
        await update.message.reply_text("خطای غیرمنتظره در ایجاد کاربر!")

    await update.message.reply_text("به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)
    return ConversationHandler.END


# مشاهده کاربران
def parse_date(date_str):
    try:
        # تلاش برای تبدیل با زمان
        return datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        # تلاش برای تبدیل بدون زمان
        return datetime.strptime(date_str, "%Y-%m-%d")

async def list_users(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("❌ شما مجاز به استفاده از این ربات نیستید.")
        return

    user_data = load_user_data()["users"]
    if user_data:
        message = "👥 کاربران موجود:\n\n"
        today = datetime.now().date()
        messages = []  # برای نگهداری بخش‌های پیام

        for user_id, details in user_data.items():
            if not isinstance(details, dict) or "expiry_date" not in details:
                logger.warning(f"Invalid data for user ID {user_id}: {details}")
                continue

            expiry_date = parse_date(details["expiry_date"]).date()
            status = "✅ فعال" if expiry_date >= today else "❌ منقضی‌شده"
            data_limit = details.get("data_limit_gb", "نامحدود")
            data_used = details.get("data_used_gb", 0)

            # اضافه کردن اطلاعات کاربر به پیام
            user_info = (
                f"ID: {user_id}\n"
                f"Name: {details['name']}\n"
                f"تاریخ انقضا: {details['expiry_date']} ({status})\n"
                f"📊 حجم کل: {data_limit} گیگابایت\n"
                f"📉 حجم مصرف‌شده: {data_used} گیگابایت\n\n"
            )
            if len(message) + len(user_info) > 4000:  # بررسی طول پیام
                messages.append(message)  # اضافه کردن پیام به لیست پیام‌ها
                message = ""  # ریست پیام فعلی

            message += user_info

        # افزودن پیام باقی‌مانده به لیست پیام‌ها
        if message:
            messages.append(message)

        # ارسال پیام‌ها
        for msg in messages:
            await update.message.reply_text(msg)
    else:
        await update.message.reply_text("هیچ کاربری یافت نشد.")

# تابع حذف کاربر
async def delete_user(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return

    await update.message.reply_text("لطفاً ID کاربری را که می‌خواهید حذف کنید وارد کنید:")
    return GET_USER_ID


async def confirm_delete_user(update: Update, context: CallbackContext):
    user_id = update.message.text.strip()
    user_data = load_user_data()

    if user_id not in user_data["users"]:
        await update.message.reply_text(f"کاربر با شناسه {user_id} وجود ندارد.")
        return ConversationHandler.END

    try:
        # حذف کاربر از Outline
        response = requests.delete(
            f"{OUTLINE_API_URL}/access-keys/{user_id}",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            verify=False,
        )

        if response.status_code == 204:
            # حذف از فایل JSON
            user_data["users"].pop(user_id, None)
            save_user_data(user_data)
            await update.message.reply_text(f"کاربر با ID {user_id} با موفقیت حذف شد.")
        elif response.status_code == 404:
            await update.message.reply_text(
                f"کاربر با شناسه {user_id} در سرور یافت نشد. فقط از فایل حذف می‌شود."
            )
            user_data["users"].pop(user_id, None)
            save_user_data(user_data)
        else:
            await update.message.reply_text(
                f"خطا در حذف کاربر از سرور!\nکد وضعیت: {response.status_code}\nپاسخ: {response.text}"
            )
    except Exception as e:
        logger.error(f"Exception in delete_user: {str(e)}")
        await update.message.reply_text("خطای غیرمنتظره در حذف کاربر!")

    return ConversationHandler.END

# هندلر درخواست پشتیبانی
async def support_request(update: Update, context: CallbackContext):
    await update.message.reply_text(
        "برای چت مستقیم با پشتیبانی روی دکمه زیر کلیک کنید:",
        reply_markup=SUPPORT_BUTTON,
    )

# راه‌اندازی ربات
def main():
    application = Application.builder().token(BOT_TOKEN).build()

    # هندلر ایجاد کاربر
    create_user_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex("^🆕 ایجاد کاربر$"), ask_for_user_name)],
        states={
            GET_USER_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, ask_for_subscription_duration)],
            GET_SUBSCRIPTION_DURATION: [MessageHandler(filters.TEXT & ~filters.COMMAND, ask_for_data_limit)],
            GET_DATA_LIMIT: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user_with_limit)],
        },
        fallbacks=[],
    )

    # هندلر حذف کاربر
    delete_user_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex("^❌ حذف کاربر$"), delete_user)],
        states={
            GET_USER_ID: [MessageHandler(filters.TEXT & ~filters.COMMAND, confirm_delete_user)],
        },
        fallbacks=[],
    )

    # اضافه کردن هندلر جدید برای درخواست پشتیبانی
    application.add_handler(MessageHandler(filters.Regex("^💬 درخواست پشتیبانی$"), support_request))
    application.add_handler(MessageHandler(filters.Regex("^🔄 دریافت آخرین آپدیت$"), check_for_update))
    application.add_handler(MessageHandler(filters.Regex("^🎯 دریافت اکانت تست$"), create_test_account))


    # هندلر برای کلیک روی "📂 پشتیبان‌گیری"
    application.add_handler(MessageHandler(filters.Text(["📂 پشتیبان‌گیری"]), show_backup_menu))
    application.add_handler(MessageHandler(filters.Text(["📥 بکاپ"]), backup_files))
    application.add_handler(MessageHandler(filters.Text(["📤 ریستور"]), restore_files))
    application.add_handler(MessageHandler(filters.Text(["🔙 بازگشت"]), back_to_main))
    application.add_handler(CallbackQueryHandler(handle_restore_callback))
    application.add_handler(MessageHandler(filters.Document.FileExtension("zip"), handle_uploaded_backup))


    # هندلرهای اصلی
    application.add_handler(CommandHandler("start", start))
    application.add_handler(create_user_handler)
    application.add_handler(delete_user_handler)
    application.add_handler(MessageHandler(filters.Regex("^👥 مشاهده کاربران$"), list_users))

    # حذف کاربران منقضی‌شده
    remove_expired_users()

    # زمان‌بندی پاکسازی کاربران منقضی‌شده
    schedule_user_cleanup()

    logger.info("Bot is starting...")
    application.run_polling()

if __name__ == "__main__":
    main()
