import logging
import os
from logging.handlers import RotatingFileHandler
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
    ConversationHandler,
    CallbackContext,
)
import sys
import zipfile

# --------------------------------------------------------------------------------
# 1) تنظیمات لاگ کلی (نمایش در کنسول / سیستم)
# --------------------------------------------------------------------------------

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.DEBUG,  # سطح کلی: تمام پیام‌های DEBUG و بالاتر
)

# لاگر ماژول فعلی
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

# کاهش سطح لاگ برای کتابخانه‌های httpx و httpcore
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

# لاگ کتابخانه تلگرام را در سطح DEBUG نگه می‌داریم
logging.getLogger("telegram").setLevel(logging.DEBUG)
logging.getLogger("telegram.ext").setLevel(logging.DEBUG)


# --------------------------------------------------------------------------------
# 2) FileHandler برای نگهداری لاگ در فایل (با چرخش لاگ)
# --------------------------------------------------------------------------------

LOG_DIR = "/opt/outline_bot/logs"
os.makedirs(LOG_DIR, exist_ok=True)

log_file_path = os.path.join(LOG_DIR, "service.log")

# تنظیم RotatingFileHandler:
file_handler = RotatingFileHandler(
    filename=log_file_path,
    maxBytes=5 * 1024 * 1024,  # حداکثر حجم فایل: 5 مگابایت
    backupCount=3             # نگهداری حداکثر 3 فایل قدیمی
)

# می‌توانید سطح لاگ برای فایل را هم روی DEBUG بگذارید
file_handler.setLevel(logging.DEBUG)

# قالب لاگ در فایل
formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
file_handler.setFormatter(formatter)

# افزودن FileHandler به لاگر ریشه (بنابراین همه پیام‌ها ذخیره می‌شوند)
logging.getLogger().addHandler(file_handler)

# اکنون می‌توانید از لاگر استفاده کنید
logger.info("Logging system initialized. All DEBUG+ logs go to console, INFO+ logs also go to file.")

# --------------------------------------------------------------------------------
# فایل قفل (در صورت نیاز)
# --------------------------------------------------------------------------------
LOCK_FILE = "/tmp/outline_bot.lock"
USE_LOCK_FILE = False  # اگر می‌خواهید از فایل قفل استفاده کنید، True کنید

if USE_LOCK_FILE and os.path.exists(LOCK_FILE):
    print("ربات در حال حاضر در حال اجرا است. فرآیند متوقف می‌شود.")
    sys.exit(1)

if USE_LOCK_FILE:
    with open(LOCK_FILE, "w") as lock:
        lock.write(str(os.getpid()))

if USE_LOCK_FILE:
    import atexit
    def remove_lock():
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)
    atexit.register(remove_lock)

# --------------------------------------------------------------------------------
# تنظیمات/خواندن فایل کانفیگ
# --------------------------------------------------------------------------------
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

CONFIG_PATH = "/opt/outline_bot/.config.json"

def load_config():
    try:
        with open(CONFIG_PATH, "r") as file:
            return json.load(file)
    except FileNotFoundError:
        raise Exception(f"فایل تنظیمات یافت نشد: {CONFIG_PATH}")
    except json.JSONDecodeError:
        raise Exception("خطا در خواندن فایل تنظیمات JSON.")

config = load_config()

BOT_TOKEN = config["BOT_TOKEN"]
ADMIN_IDS = config["ADMIN_IDS"]
OUTLINE_API_URL = config["OUTLINE_API_URL"]
OUTLINE_API_KEY = config["OUTLINE_API_KEY"]
CERT_SHA256 = config["CERT_SHA256"]  # اگر نیاز ندارید می‌توانید حذف کنید
DATA_FILE = "/opt/outline_bot/users_data.json"

BOT_VERSION = "1.37.3"

# --------------------------------------------------------------------------------
# تنظیم لاگر اختصاصی برای پشتیبان‌گیری
# --------------------------------------------------------------------------------
backup_logger = logging.getLogger("backup_restore")
backup_logger.setLevel(logging.DEBUG)

console_handler = logging.StreamHandler()
console_handler.setLevel(logging.DEBUG)
console_formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
console_handler.setFormatter(console_formatter)

backup_logger.addHandler(console_handler)
# در صورت نیاز، می‌توانید یک FileHandler اضافه کنید یا سطح لاگ این logger را تغییر دهید.


# --------------------------------------------------------------------------------
# ثابت‌ها و مقادیر گفتگو
# --------------------------------------------------------------------------------
GET_USER_NAME = 1
GET_SUBSCRIPTION_DURATION = 2
GET_DATA_LIMIT = 3
GET_USER_ID = 4  # برای حذف

MAIN_KEYBOARD = ReplyKeyboardMarkup(
    [
        ["🆕 ایجاد کاربر", "👥 مشاهده کاربران"],
        ["❌ حذف کاربر", "💬 درخواست پشتیبانی"],
        ["🔄 دریافت آخرین آپدیت", "🎯 دریافت اکانت تست"],
        ["📂 پشتیبان‌گیری"]
    ],
    resize_keyboard=True,
)

BACKUP_MENU_KEYBOARD = ReplyKeyboardMarkup(
    [
        ["📥 بکاپ", "📤 ریستور"],
        ["🔙 بازگشت"]
    ],
    resize_keyboard=True
)

def is_admin(update: Update) -> bool:
    return update.effective_user.id in ADMIN_IDS

# --------------------------------------------------------------------------------
# مدیریت اطلاعات کاربران
# --------------------------------------------------------------------------------
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


# --------------------------------------------------------------------------------
# تابع کمکی ایجاد کاربر Outline
# --------------------------------------------------------------------------------
def create_outline_user(name: str, data_limit_gb: int) -> (str, str):
    """
    یک کاربر جدید در سرور Outline ایجاد می‌کند و حجم مصرفی (GB) را اعمال می‌نماید.
    خروجی: (user_id, access_url) یا (None, None) در صورت بروز خطا
    """
    try:
        logger.debug(f"Attempting to create a new Outline user: {name} with limit {data_limit_gb} GB")
        response = requests.post(
            f"{OUTLINE_API_URL}/access-keys",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            json={"name": name},
            verify=False,
        )
        if response.status_code not in [200, 201]:
            logger.error(f"خطا در ایجاد کاربر: {response.status_code}, {response.text}")
            return None, None

        data = response.json()
        user_id = data["id"]
        access_url = data["accessUrl"]
        logger.debug(f"User created with id={user_id}, raw accessUrl={access_url}")

        # جایگزینی دامنه (اختیاری)
        domain_name = OUTLINE_API_URL.split("//")[1].split(":")[0]
        if "@" in access_url:
            parts = access_url.split("@")
            after_at = parts[1].split(":")
            after_at[0] = domain_name
            access_url = f"{parts[0]}@{':'.join(after_at)}"

        # تنظیم محدودیت حجمی
        limit_bytes = data_limit_gb * 1024**3
        limit_response = requests.put(
            f"{OUTLINE_API_URL}/access-keys/{user_id}/data-limit",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            json={"limit": {"bytes": limit_bytes}},
            verify=False,
        )
        if limit_response.status_code != 204:
            logger.warning(f"خطا در اعمال محدودیت حجمی: {limit_response.status_code}, {limit_response.text}")

        return user_id, access_url

    except Exception as e:
        logger.error(f"Exception in create_outline_user: {str(e)}")
        return None, None


# --------------------------------------------------------------------------------
# ایجاد اکانت تست
# --------------------------------------------------------------------------------
async def create_test_account(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این بخش نیستید.")
        return

    user = update.effective_user
    logger.debug(f"Admin {user.id} is creating a test account")

    test_user_name = f"Test-{user.id}"
    expiry_date = datetime.now() + timedelta(hours=1)  # 1 ساعت
    data_limit_gb = 1

    user_id, access_url = create_outline_user(test_user_name, data_limit_gb)
    if not user_id:
        await update.message.reply_text("خطا در ایجاد اکانت تست!")
        return

    # ذخیره در فایل JSON
    all_data = load_user_data()
    all_data["users"][str(user_id)] = {
        "name": test_user_name,
        "expiry_date": expiry_date.strftime("%Y-%m-%d %H:%M:%S"),
        "accessUrl": access_url,
        "data_limit_gb": data_limit_gb,
    }
    save_user_data(all_data)

    message = (
        f"اکانت تست با موفقیت ایجاد شد! 🎉\n\n"
        f"Name: {test_user_name}\n"
        f"انقضا: {expiry_date.strftime('%Y-%m-%d %H:%M:%S')}\n"
        f"حجم مصرفی مجاز: {data_limit_gb} GB\n\n"
        f"لینک اتصال:\n{access_url}"
    )
    await update.message.reply_text(message, reply_markup=MAIN_KEYBOARD)


# --------------------------------------------------------------------------------
# گفتگو برای ایجاد کاربر جدید (سه مرحله)
# --------------------------------------------------------------------------------
GET_USER_NAME = 1
GET_SUBSCRIPTION_DURATION = 2
GET_DATA_LIMIT = 3

async def ask_for_user_name(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return ConversationHandler.END

    logger.debug(f"Admin {update.effective_user.id} pressed 'Create user'. Asking for user name.")
    await update.message.reply_text("لطفاً نام کاربر جدید را وارد کنید:")
    return GET_USER_NAME

async def ask_for_subscription_duration(update: Update, context: CallbackContext):
    user_name = update.message.text.strip()
    context.user_data["user_name"] = user_name

    # بررسی نام تکراری
    user_data = load_user_data()
    for details in user_data["users"].values():
        if details["name"] == user_name:
            await update.message.reply_text("این نام کاربری قبلاً ثبت شده است. لطفاً نام دیگری انتخاب کنید.")
            logger.debug(f"Duplicate user name {user_name} was entered.")
            return ConversationHandler.END

    await update.message.reply_text(
        "لطفاً مدت زمان اشتراک را انتخاب کنید:\n1️⃣ یک ماه\n2️⃣ دو ماه\n3️⃣ سه ماه",
        reply_markup=ReplyKeyboardMarkup([["1 ماه", "2 ماه", "3 ماه"], ["بازگشت"]], resize_keyboard=True),
    )
    return GET_SUBSCRIPTION_DURATION

async def ask_for_data_limit(update: Update, context: CallbackContext):
    duration_text = update.message.text
    if duration_text == "بازگشت":
        await update.message.reply_text("عملیات لغو شد. به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)
        logger.debug("User cancelled the operation in subscription duration step.")
        return ConversationHandler.END

    if duration_text not in ["1 ماه", "2 ماه", "3 ماه"]:
        await update.message.reply_text("لطفاً یک گزینه معتبر انتخاب کنید.")
        logger.debug(f"Invalid subscription duration: {duration_text}")
        return GET_SUBSCRIPTION_DURATION

    duration_map = {"1 ماه": 1, "2 ماه": 2, "3 ماه": 3}
    context.user_data["subscription_months"] = duration_map[duration_text]
    logger.debug(f"Selected subscription duration: {duration_text} -> {duration_map[duration_text]} month(s)")

    await update.message.reply_text(
        "لطفاً حجم مصرفی مجاز (بر حسب گیگابایت) را وارد کنید (عدد صحیح):",
        reply_markup=ReplyKeyboardMarkup([["بازگشت"]], resize_keyboard=True),
    )
    return GET_DATA_LIMIT

async def finalize_create_user(update: Update, context: CallbackContext):
    data_limit_str = update.message.text.strip()
    if data_limit_str == "بازگشت":
        await update.message.reply_text("عملیات لغو شد. به منوی اصلی بازگشتید.", reply_markup=MAIN_KEYBOARD)
        logger.debug("User cancelled the operation in data limit step.")
        return ConversationHandler.END

    if not data_limit_str.isdigit() or int(data_limit_str) <= 0:
        await update.message.reply_text("لطفاً یک عدد مثبت وارد کنید.")
        logger.debug(f"Invalid data limit input: {data_limit_str}")
        return GET_DATA_LIMIT

    data_limit_gb = int(data_limit_str)
    user_name = context.user_data["user_name"]
    months = context.user_data["subscription_months"]
    expiry_date = datetime.now() + timedelta(days=30 * months)

    logger.debug(f"Creating Outline user with name={user_name}, limit={data_limit_gb} GB, months={months}")

    user_id, access_url = create_outline_user(user_name, data_limit_gb)
    if not user_id:
        await update.message.reply_text("خطا در ایجاد کاربر جدید!")
        logger.error("Failed to create user.")
        return ConversationHandler.END

    # ذخیره در فایل
    all_data = load_user_data()
    all_data["users"][str(user_id)] = {
        "name": user_name,
        "expiry_date": expiry_date.strftime("%Y-%m-%d %H:%M:%S"),
        "accessUrl": access_url,
        "data_limit_gb": data_limit_gb,
    }
    save_user_data(all_data)

    message = (
        f"کاربر جدید ایجاد شد! 🎉\n\n"
        f"نام: {user_name}\n"
        f"تاریخ انقضا: {expiry_date.strftime('%Y-%m-%d %H:%M:%S')}\n"
        f"حجم مصرفی مجاز: {data_limit_gb} گیگ\n\n"
        f"لینک اتصال:\n{access_url}\n\n"
        f"لینک دانلود برنامه‌های Outline:\n"
        f"[iOS](https://apps.apple.com/us/app/outline-app/id1356177741)\n"
        f"[Android](https://play.google.com/store/apps/details?id=org.outline.android.client&hl=en)\n"
        f"[Windows](https://s3.amazonaws.com/outline-releases/client/windows/stable/Outline-Client.exe)\n"
        f"[Mac](https://apps.apple.com/us/app/outline-secure-internet-access/id1356178125?mt=12)"
    )
    await update.message.reply_text(message, parse_mode="Markdown", reply_markup=MAIN_KEYBOARD)

    return ConversationHandler.END


# --------------------------------------------------------------------------------
# مشاهده کاربران
# --------------------------------------------------------------------------------
def parse_date(date_str):
    try:
        return datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return datetime.strptime(date_str, "%Y-%m-%d")

async def list_users(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("❌ شما مجاز به استفاده از این ربات نیستید.")
        return

    logger.debug(f"Admin {update.effective_user.id} requested user list.")
    user_data = load_user_data()["users"]
    if user_data:
        messages = []
        chunk = "👥 کاربران موجود:\n\n"
        today = datetime.now().date()

        for user_id, details in user_data.items():
            if not isinstance(details, dict) or "expiry_date" not in details:
                logger.warning(f"Invalid data for user ID {user_id}: {details}")
                continue

            expiry_dt = parse_date(details["expiry_date"])
            expiry_date_only = expiry_dt.date()
            status = "✅ فعال" if expiry_date_only >= today else "❌ منقضی‌شده"
            data_limit = details.get("data_limit_gb", "نامحدود")
            data_used = details.get("data_used_gb", 0)

            user_info = (
                f"ID: {user_id}\n"
                f"Name: {details['name']}\n"
                f"تاریخ انقضا: {details['expiry_date']} ({status})\n"
                f"📊 حجم کل: {data_limit} GB\n"
                f"📉 حجم مصرف‌شده: {data_used} GB\n\n"
            )

            if len(chunk) + len(user_info) > 4000:
                messages.append(chunk)
                chunk = ""

            chunk += user_info

        if chunk:
            messages.append(chunk)

        for msg in messages:
            await update.message.reply_text(msg)
    else:
        await update.message.reply_text("هیچ کاربری یافت نشد.")


# --------------------------------------------------------------------------------
# حذف کاربر
# --------------------------------------------------------------------------------
async def delete_user(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return ConversationHandler.END

    logger.debug(f"Admin {update.effective_user.id} pressed 'Delete user'.")
    await update.message.reply_text("لطفاً ID کاربری را که می‌خواهید حذف کنید وارد کنید:")
    return GET_USER_ID

async def confirm_delete_user(update: Update, context: CallbackContext):
    user_id = update.message.text.strip()
    user_data = load_user_data()

    if user_id not in user_data["users"]:
        await update.message.reply_text(f"کاربر با شناسه {user_id} در فایل یافت نشد.")
        logger.debug(f"User ID {user_id} not found in local file.")
        return ConversationHandler.END

    logger.debug(f"Deleting user with ID: {user_id}")
    try:
        response = requests.delete(
            f"{OUTLINE_API_URL}/access-keys/{user_id}",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            verify=False,
        )

        if response.status_code == 204:
            user_data["users"].pop(user_id, None)
            save_user_data(user_data)
            await update.message.reply_text(f"کاربر با ID {user_id} با موفقیت حذف شد.")
            logger.info(f"User with ID {user_id} successfully deleted.")
        elif response.status_code == 404:
            await update.message.reply_text(
                f"کاربر با شناسه {user_id} در سرور یافت نشد. از فایل حذف می‌شود."
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


# --------------------------------------------------------------------------------
# حذف کاربران منقضی‌شده (اتوماسیون)
# --------------------------------------------------------------------------------
def parse_date(date_str):
    try:
        return datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return datetime.strptime(date_str, "%Y-%m-%d")

def check_expired_users():
    now = datetime.now()
    user_data = load_user_data()["users"]
    expired = []

    for uid, info in user_data.items():
        expiry_date_str = info.get("expiry_date")
        if not expiry_date_str:
            continue
        try:
            expiry_dt = parse_date(expiry_date_str)
            if expiry_dt < now:
                expired.append(uid)
        except ValueError:
            logger.error(f"تاریخ نامعتبر برای کاربر {uid}: {expiry_date_str}")
    return expired

def remove_expired_users():
    expired_users = check_expired_users()
    if expired_users:
        all_data = load_user_data()
        for uid in expired_users:
            logger.debug(f"Removing expired user: {uid}")
            resp = requests.delete(
                f"{OUTLINE_API_URL}/access-keys/{uid}",
                headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                verify=False,
            )
            if resp.status_code == 204:
                all_data["users"].pop(uid, None)
                save_user_data(all_data)
                logger.info(f"کاربر منقضی‌شده با شناسه {uid} حذف شد.")
            elif resp.status_code == 404:
                # فقط در فایل بوده
                all_data["users"].pop(uid, None)
                save_user_data(all_data)

def schedule_user_cleanup():
    remove_expired_users()
    # فاصله زمانی 1 ساعت (3600 ثانیه) به عنوان نمونه
    Timer(3600, schedule_user_cleanup).start()
    logger.debug("Scheduled next expired user removal in 3600 seconds.")


# --------------------------------------------------------------------------------
# پشتیبان‌گیری و ریستور
# --------------------------------------------------------------------------------
async def show_backup_menu(update, context):
    logger.debug(f"Admin {update.effective_user.id} opened backup menu.")
    await update.message.reply_text(
        "لطفاً یکی از گزینه‌های زیر را انتخاب کنید:",
        reply_markup=BACKUP_MENU_KEYBOARD
    )

async def backup_files(update, context):
    logger.debug(f"Admin {update.effective_user.id} requested backup.")
    backup_path = "/opt/outline_bot/backup_restore/backup_file"
    os.makedirs(backup_path, exist_ok=True)

    files_to_backup = [
        "/opt/outline_bot/users_data.json",
        "/opt/outline/persisted-state/shadowbox_config.json",
        "/opt/outline/persisted-state/outline-ss-server/config.yml"
    ]

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    backup_file = os.path.join(backup_path, f"backup_{timestamp}.zip")

    try:
        with zipfile.ZipFile(backup_file, "w") as zipf:
            for file_path in files_to_backup:
                if os.path.exists(file_path):
                    zipf.write(file_path, os.path.basename(file_path))
                    backup_logger.info(f"File {file_path} added to backup.")
                else:
                    backup_logger.warning(f"File {file_path} does not exist.")

        await update.message.reply_text("بکاپ با موفقیت ایجاد شد! فایل در حال ارسال است...")
        backup_logger.info(f"Backup created successfully at {backup_file}")

        with open(backup_file, "rb") as f:
            await context.bot.send_document(
                chat_id=update.effective_chat.id,
                document=f,
                filename=f"backup_{timestamp}.zip",
                caption="📂 فایل بکاپ ایجاد شده و ارسال می‌شود."
            )
    except Exception as e:
        await update.message.reply_text("خطایی در ایجاد بکاپ رخ داد!")
        backup_logger.error(f"Error creating backup: {str(e)}")

async def restore_files(update, context):
    logger.debug(f"Admin {update.effective_user.id} requested restore files list.")
    backup_path = "/opt/outline_bot/backup_restore/backup_file"
    os.makedirs(backup_path, exist_ok=True)

    backup_files = os.listdir(backup_path)
    backup_files = [f for f in backup_files if f.endswith(".zip")]
    backup_files.sort()

    keyboard = []
    if backup_files:
        keyboard.extend([[InlineKeyboardButton(file, callback_data=f"restore_{file}")] for file in backup_files])
    else:
        await update.message.reply_text("❌ هیچ بکاپی در سرور وجود ندارد.")

    # دکمه آپلود فایل
    keyboard.append([InlineKeyboardButton("ارسال فایل از سیستم", callback_data="upload_backup")])

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text("لطفاً یک فایل برای ریستور انتخاب کنید:", reply_markup=reply_markup)
    backup_logger.info(f"Available backups listed for restore: {backup_files}")

async def handle_restore_callback(update, context):
    query = update.callback_query
    await query.answer()

    data = query.data
    if data.startswith("restore_"):
        file_name = data.replace("restore_", "")
        await restore_selected_file(file_name, update, from_user_upload=False)
    elif data == "upload_backup":
        await prompt_upload_backup(update, context)

async def prompt_upload_backup(update: Update, context: CallbackContext):
    logger.debug("Prompting user to upload backup file...")
    try:
        await update.callback_query.message.reply_text(
            "📤 لطفاً فایل بکاپ خود را ارسال کنید. فایل باید فرمت ZIP داشته باشد.\n"
            "⏬ منتظر بارگذاری فایل شما هستیم..."
        )
    except Exception as e:
        backup_logger.error(f"Error prompting for backup upload: {str(e)}")

async def handle_uploaded_backup(update, context):
    logger.debug(f"Received uploaded file from {update.effective_user.id}.")
    try:
        if not update.message or not update.message.document:
            await update.message.reply_text("فایل معتبری ارسال نشده است.")
            return

        file = update.message.document
        if not file.file_name.endswith(".zip"):
            await update.message.reply_text("فایل ارسالی باید با فرمت ZIP باشد.")
            return

        tg_file = await file.get_file()
        restore_path = "/opt/outline_bot/backup_restore/restore_file"
        os.makedirs(restore_path, exist_ok=True)
        file_path = os.path.join(restore_path, file.file_name)

        await tg_file.download_to_drive(file_path)
        await update.message.reply_text("✅ فایل با موفقیت دریافت شد. در حال ریستور بکاپ هستیم...")

        await restore_selected_file(file.file_name, update, from_user_upload=True)

    except Exception as e:
        await update.message.reply_text("❌ خطا در دریافت و ریستور فایل بکاپ!")
        backup_logger.error(f"Error handling uploaded backup: {str(e)}")

async def restore_selected_file(file_name, update, from_user_upload=False):
    logger.debug(f"Restoring file {file_name}, from_user_upload={from_user_upload}")
    try:
        if from_user_upload:
            restore_path = "/opt/outline_bot/backup_restore/restore_file"
        else:
            restore_path = "/opt/outline_bot/backup_restore/backup_file"

        backup_file_path = os.path.join(restore_path, file_name)
        if not os.path.exists(backup_file_path):
            msg = f"فایل بکاپ {file_name} یافت نشد."
            backup_logger.warning(msg)
            if update.callback_query and update.callback_query.message:
                await update.callback_query.message.reply_text(msg)
            return

        # فایل‌های اصلی
        target_paths = {
            "users_data.json": "/opt/outline_bot/users_data.json",
            "shadowbox_config.json": "/opt/outline/persisted-state/shadowbox_config.json",
            "config.yml": "/opt/outline/persisted-state/outline-ss-server/config.yml",
        }

        with zipfile.ZipFile(backup_file_path, 'r') as zip_ref:
            zip_ref.extractall(restore_path)

        for extracted_file in zip_ref.namelist():
            if extracted_file in target_paths:
                src = os.path.join(restore_path, extracted_file)
                dst = target_paths[extracted_file]
                os.replace(src, dst)
                backup_logger.info(f"Restored {extracted_file} to {dst}")

        # پیام موفقیت
        success_text = f"ریستور فایل {file_name} با موفقیت انجام شد!"
        if update.message:
            await update.message.reply_text(success_text)
        elif update.callback_query and update.callback_query.message:
            await update.callback_query.message.reply_text(success_text)

        # ریستارت سرویس‌ها
        msg_text = "♻️ در حال ریستارت سرویس‌ها، لطفاً منتظر بمانید..."
        if update.callback_query and update.callback_query.message:
            await update.callback_query.message.reply_text(msg_text)
        elif update.message:
            await update.message.reply_text(msg_text)

        try:
            subprocess.run(["docker", "restart", "shadowbox"], check=True)
            subprocess.run(["docker", "restart", "watchtower"], check=True)
            subprocess.run(["sudo", "systemctl", "restart", "outline_bot.service"], check=True)

            final_text = "✅ سرویس‌ها با موفقیت ریستارت شدند!"
            if update.callback_query and update.callback_query.message:
                await update.callback_query.message.reply_text(final_text)
            elif update.message:
                await update.message.reply_text(final_text)

            backup_logger.info("Services restarted successfully.")
        except subprocess.CalledProcessError as e:
            err_text = "❌ خطا در ریستارت سرویس‌ها!"
            backup_logger.error(f"Error restarting services: {str(e)}")
            if update.callback_query and update.callback_query.message:
                await update.callback_query.message.reply_text(err_text)
            elif update.message:
                await update.message.reply_text(err_text)

    except Exception as e:
        backup_logger.error(f"Error restoring file {file_name}: {str(e)}")
        if update.callback_query and update.callback_query.message:
            await update.callback_query.message.reply_text("خطا در فرآیند ریستور.")

async def back_to_main(update, context):
    logger.debug(f"User {update.effective_user.id} returned to main menu.")
    await update.message.reply_text("بازگشت به منوی اصلی:", reply_markup=MAIN_KEYBOARD)


# --------------------------------------------------------------------------------
# بررسی و دریافت آخرین آپدیت
# --------------------------------------------------------------------------------
async def check_for_update(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return

    GITHUB_VERSION_URL = "https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/version.txt"
    LOCAL_VERSION_FILE = "/opt/outline_bot/version.txt"
    LOCAL_UPDATE_SCRIPT = "/opt/outline_bot/update.sh"

    logger.debug(f"Admin {update.effective_user.id} checking for update.")

    try:
        # نسخه فعلی
        try:
            with open(LOCAL_VERSION_FILE, "r") as file:
                current_version = file.read().strip()
        except FileNotFoundError:
            current_version = "unknown"

        response = requests.get(GITHUB_VERSION_URL)
        if response.status_code == 200:
            latest_version = response.text.strip()

            if current_version == latest_version:
                await update.message.reply_text(
                    f"شما در حال استفاده از آخرین نسخه هستید: {current_version}"
                )
            else:
                await update.message.reply_text(
                    f"نسخه جدیدی در دسترس است: {latest_version}\n\n"
                    "لطفاً صبور باشید، فرآیند به‌روزرسانی آغاز می‌شود..."
                )

                process = subprocess.run(["sudo", "bash", LOCAL_UPDATE_SCRIPT], capture_output=True, text=True)
                if process.returncode == 0:
                    await update.message.reply_text(
                        f"به‌روزرسانی با موفقیت انجام شد!\nنسخه جدید: {latest_version}\n"
                        "ربات شما اکنون آماده استفاده است."
                    )
                else:
                    await update.message.reply_text(
                        "خطا در فرآیند به‌روزرسانی. لطفاً لاگ‌ها را بررسی کنید یا به صورت دستی اقدام کنید."
                    )
        else:
            await update.message.reply_text("خطا در بررسی نسخه جدید. بعداً دوباره تلاش کنید.")
    except Exception as e:
        await update.message.reply_text(f"خطای غیرمنتظره در بررسی/اجرای به‌روزرسانی: {e}")


# --------------------------------------------------------------------------------
# هندلر درخواست پشتیبانی
# --------------------------------------------------------------------------------
SUPPORT_BUTTON = InlineKeyboardMarkup(
    [
        [InlineKeyboardButton("چت با پشتیبانی", url="https://t.me/irannetwork_co")]
    ]
)
async def support_request(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return

    logger.debug(f"Admin {update.effective_user.id} requested support info.")
    await update.message.reply_text(
        "برای چت مستقیم با پشتیبانی روی دکمه زیر کلیک کنید:",
        reply_markup=SUPPORT_BUTTON,
    )


# --------------------------------------------------------------------------------
# دستور /start ربات
# --------------------------------------------------------------------------------
async def start(update: Update, context: CallbackContext):
    user = update.effective_user
    if not is_admin(update):
        logger.warning(f"Unauthorized access attempt by {user.first_name} ({user.id})")
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return

    logger.info(f"Admin {user.id} started the bot.")
    await update.message.reply_text(
        "سلام! برای مدیریت سرور Outline یکی از گزینه‌های زیر را انتخاب کنید.",
        reply_markup=MAIN_KEYBOARD,
    )


# --------------------------------------------------------------------------------
# تابع اصلی (main)
# --------------------------------------------------------------------------------
def main():
    application = Application.builder().token(BOT_TOKEN).build()

    # ساخت ConversationHandler برای ایجاد کاربر
    create_user_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex("^🆕 ایجاد کاربر$"), ask_for_user_name)],
        states={
            GET_USER_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, ask_for_subscription_duration)],
            GET_SUBSCRIPTION_DURATION: [MessageHandler(filters.TEXT & ~filters.COMMAND, ask_for_data_limit)],
            GET_DATA_LIMIT: [MessageHandler(filters.TEXT & ~filters.COMMAND, finalize_create_user)],
        },
        fallbacks=[],
    )

    # ساخت ConversationHandler برای حذف کاربر
    delete_user_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex("^❌ حذف کاربر$"), delete_user)],
        states={
            GET_USER_ID: [MessageHandler(filters.TEXT & ~filters.COMMAND, confirm_delete_user)],
        },
        fallbacks=[],
    )

    # ثبت هندلرهای اصلی
    application.add_handler(CommandHandler("start", start))
    application.add_handler(create_user_handler)
    application.add_handler(delete_user_handler)
    application.add_handler(MessageHandler(filters.Regex("^👥 مشاهده کاربران$"), list_users))
    application.add_handler(MessageHandler(filters.Regex("^💬 درخواست پشتیبانی$"), support_request))
    application.add_handler(MessageHandler(filters.Regex("^🔄 دریافت آخرین آپدیت$"), check_for_update))
    application.add_handler(MessageHandler(filters.Regex("^🎯 دریافت اکانت تست$"), create_test_account))

    # پشتیبان‌گیری
    application.add_handler(MessageHandler(filters.Text(["📂 پشتیبان‌گیری"]), show_backup_menu))
    application.add_handler(MessageHandler(filters.Text(["📥 بکاپ"]), backup_files))
    application.add_handler(MessageHandler(filters.Text(["📤 ریستور"]), restore_files))
    application.add_handler(MessageHandler(filters.Text(["🔙 بازگشت"]), back_to_main))

    # کال‌بک‌هندلر برای دکمه‌های ریستور
    application.add_handler(CallbackQueryHandler(handle_restore_callback))
    # هندلر برای دریافت فایل ZIP آپلودی
    application.add_handler(MessageHandler(filters.Document.FileExtension("zip"), handle_uploaded_backup))

    # حذف کاربران منقضی‌شده در شروع
    remove_expired_users()
    # زمان‌بندی اتوماتیک حذف کاربران منقضی‌شده
    schedule_user_cleanup()

    def graceful_shutdown(*args):
        logger.info("Shutting down gracefully...")
        sys.exit(0)

    signal.signal(signal.SIGTERM, graceful_shutdown)
    signal.signal(signal.SIGINT, graceful_shutdown)

    logger.info("Bot is starting...")
    application.run_polling()


if __name__ == "__main__":
    main()
