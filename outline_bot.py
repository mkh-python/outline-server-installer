import logging
from telegram import InlineKeyboardMarkup, InlineKeyboardButton

import requests
import json
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

# تنظیمات سرور Outline
OUTLINE_API_URL = "https://135.181.146.198:63910/jdTpo2-adll3al4hGC0VWA"
OUTLINE_API_KEY = "jdTpo2-adll3al4hGC0VWA"
CERT_SHA256 = "C3F2504EA3BD73B3B777E418BB20A39C89E8ABD341F2EA7FE729F1FE73E11C35"
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

# دکمه‌های ثابت
MAIN_KEYBOARD = ReplyKeyboardMarkup(
    [
        ["🆕 ایجاد کاربر", "👥 مشاهده کاربران"],
        ["❌ حذف کاربر", "💬 درخواست پشتیبانی"],
    ],
    resize_keyboard=True,
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

# آیدی مدیران
ADMIN_IDS = [7819156066, 671715232]


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
    with open(DATA_FILE, "w") as file:
        json.dump(data, file, indent=4)

# بررسی کاربران منقضی‌شده
def check_expired_users():
    user_data = load_user_data()["users"]
    today = datetime.now().date()
    expired_users = [
        user_id for user_id, details in user_data.items()
        if datetime.strptime(details["expiry_date"], "%Y-%m-%d").date() < today
    ]
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

            # ذخیره اطلاعات کاربر در فایل JSON
            user_data = load_user_data()
            user_data["users"][str(user_id)] = {
                "name": user_name,
                "expiry_date": expiry_date.strftime("%Y-%m-%d"),
                "accessUrl": data["accessUrl"],
            }
            save_user_data(user_data)

            # پیام نهایی
            message = (
                f"کاربر جدید ایجاد شد! 🎉\n\n"
                f"ID: {user_id}\n"
                f"Name: {user_name}\n"
                f"تاریخ انقضا: {expiry_date.strftime('%Y-%m-%d')}\n\n"
                f"لینک اتصال:\n"
                f"{data['accessUrl']}\n\n"
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
async def list_users(update: Update, context: CallbackContext):
    if not is_admin(update):
        await update.message.reply_text("شما مجاز به استفاده از این ربات نیستید.")
        return

    user_data = load_user_data()["users"]
    if user_data:
        message = "👥 کاربران موجود:\n\n"
        today = datetime.now().date()

        for user_id, details in user_data.items():
            if not isinstance(details, dict) or "expiry_date" not in details:
                logger.warning(f"Invalid data for user ID {user_id}: {details}")
                continue

            expiry_date = datetime.strptime(details["expiry_date"], "%Y-%m-%d").date()
            status = "✅ فعال" if expiry_date >= today else "❌ منقضی‌شده"
            message += (
                f"ID: {user_id}\n"
                f"Name: {details['name']}\n"
                f"تاریخ انقضا: {details['expiry_date']} ({status})\n\n"
            )

        await update.message.reply_text(message)
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
    BOT_TOKEN = "7066784879:AAGXV-cpw68qtbxiGxlKjboRQqTgG5gF3f8"
    application = Application.builder().token(BOT_TOKEN).build()

    # هندلر ایجاد کاربر
    create_user_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex("^🆕 ایجاد کاربر$"), ask_for_user_name)],
        states={
            GET_USER_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, ask_for_subscription_duration)],
            GET_SUBSCRIPTION_DURATION: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user)],
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



    # هندلرهای اصلی
    application.add_handler(CommandHandler("start", start))
    application.add_handler(create_user_handler)
    application.add_handler(delete_user_handler)
    application.add_handler(MessageHandler(filters.Regex("^👥 مشاهده کاربران$"), list_users))

    # حذف کاربران منقضی‌شده
    remove_expired_users()

    logger.info("Bot is starting...")
    application.run_polling()

if __name__ == "__main__":
    main()
