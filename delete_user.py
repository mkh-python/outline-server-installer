import logging
import json
from datetime import datetime
import requests

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
OUTLINE_API_URL = config["OUTLINE_API_URL"]
OUTLINE_API_KEY = config["OUTLINE_API_KEY"]
DATA_FILE = config["DATA_FILE"]

# تنظیمات لاگ
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("delete_user")

# مدیریت اطلاعات کاربران
def load_user_data():
    try:
        with open(DATA_FILE, "r") as file:
            return json.load(file)
    except FileNotFoundError:
        logger.warning("فایل اطلاعات کاربران یافت نشد.")
        return {"next_id": 1, "users": {}}

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

# حذف کاربران منقضی‌شده
def remove_expired_users():
    expired_users = check_expired_users()
    if expired_users:
        user_data = load_user_data()
        for user_id in expired_users:
            try:
                response = requests.delete(
                    f"{OUTLINE_API_URL}/access-keys/{user_id}",
                    headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
                    verify=False,
                )
                if response.status_code == 204:
                    user_data["users"].pop(user_id, None)
                    logger.info(f"کاربر با ID {user_id} حذف شد.")
                elif response.status_code == 404:
                    logger.warning(f"کاربر با ID {user_id} در سرور یافت نشد. از فایل حذف می‌شود.")
                    user_data["users"].pop(user_id, None)
                else:
                    logger.warning(
                        f"خطا در حذف کاربر با ID {user_id}: {response.status_code} - {response.text}"
                    )
            except Exception as e:
                logger.error(f"خطای غیرمنتظره در حذف کاربر با ID {user_id}: {e}")
        save_user_data(user_data)
    else:
        logger.info("هیچ کاربر منقضی‌شده‌ای یافت نشد.")

if __name__ == "__main__":
    logger.info("شروع بررسی و حذف کاربران منقضی‌شده...")
    remove_expired_users()
    logger.info("بررسی و حذف کاربران منقضی‌شده به پایان رسید.")
