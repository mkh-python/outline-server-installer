import requests
import logging

# تنظیمات سرور Outline
OUTLINE_API_URL = ""
OUTLINE_API_KEY = ""

# تنظیمات لاگ
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

def delete_user(user_id):
    """
    حذف کاربر با شناسه مشخص از سرور Outline.

    Args:
        user_id (str): شناسه کاربر که باید حذف شود.
    """
    logger.info(f"در حال حذف کاربر با شناسه: {user_id}")
    
    try:
        # ارسال درخواست حذف به API
        response = requests.delete(
            f"{OUTLINE_API_URL}/access-keys/{user_id}",
            headers={"Authorization": f"Bearer {OUTLINE_API_KEY}"},
            verify=False,
        )
        # بررسی وضعیت پاسخ
        if response.status_code == 204:
            logger.info(f"کاربر با شناسه {user_id} با موفقیت حذف شد.")
            print(f"کاربر با شناسه {user_id} با موفقیت حذف شد.")
        else:
            logger.error(f"خطا در حذف کاربر: {response.status_code} {response.text}")
            print(f"خطا در حذف کاربر: {response.status_code} {response.text}")
    except Exception as e:
        logger.error(f"خطای غیرمنتظره در حذف کاربر: {str(e)}")
        print(f"خطای غیرمنتظره در حذف کاربر: {str(e)}")

if __name__ == "__main__":
    user_id = input("لطفاً شناسه کاربر را برای حذف وارد کنید: ")
    delete_user(user_id)
