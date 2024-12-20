# Outline Server Installer

This repository contains an automated script to install and configure the Outline Server alongside a Telegram bot for managing server users. The script streamlines the installation process, sets up the required environment, and ensures the bot operates seamlessly.

---

## What's New?

### Version 1.37.3.4
- Enhanced user data management: Added data usage limits and tracking.
- Improved update process: Automatically checks and installs updates from GitHub.
- Bug fixes and performance improvements.

---

## Features

- **Full Outline Server Installation**: Automatically installs the Outline Server using the official Outline Manager script.
- **Telegram Bot Integration**:
  - Supports user management via Telegram.
  - Sends automatic messages with server details upon installation.
  - Allows for multi-admin configuration.
- **Systemd Service Setup**: Configures the bot to run as a service, ensuring it starts automatically on server boot.
- **Customizable Dependencies**: Automatically installs Python dependencies (`python-telegram-bot`, `requests`) required by the bot.
- **Cross-Platform Management Links**: Provides links for managing the Outline server on Windows, Mac, and Linux.

---

## Prerequisites

- **Operating System**: Ubuntu or any Debian-based Linux distribution.
- **Network**: Ensure the server has a stable internet connection.
- **Permissions**: Run the script as a user with `sudo` privileges.

---

## Installation Steps

### 1. Run the Installation Script

Execute the following command to download and run the installer:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/mkh-python/outline-server-installer/main/install.sh)"
```

### 2. Provide Configuration Details

During installation, the script will prompt you for:
- **Telegram Bot Token**: Obtain this token by creating a bot using [BotFather](https://core.telegram.org/bots#botfather).
- **Admin IDs**: Add one or more numeric Telegram user IDs to manage the bot. (Enter `n` to finish.)

### 3. Wait for Completion

The script will:
- Install and configure the Outline Server.
- Set up a virtual environment for the bot.
- Install necessary Python dependencies.
- Configure and start the bot as a systemd service.

---

## Updating the Bot and Server

1. Open your bot in Telegram and click "🔄 Get Latest Update."
2. The bot will automatically:
   - Check for new versions on GitHub.
   - Download and apply updates.
   - Restart the bot service.

3. Upon successful update, you will receive a confirmation message with the new version.

---

## Server Details

Upon successful installation, the bot will send the following details to the admin:

- **Server API URL**: Required to manage the server via Outline Manager.
- **Cert SHA256**: Secure key for verifying the connection.
- **Download Links**:
  - Windows: [Outline Manager for Windows](https://s3.amazonaws.com/outline-releases/manager/windows/stable/Outline-Manager.exe)
  - Mac: [Outline Manager for Mac](https://s3.amazonaws.com/outline-releases/manager/macos/stable/Outline-Manager.dmg)
  - Linux: [Outline Manager for Linux](https://s3.amazonaws.com/outline-releases/manager/linux/stable/Outline-Manager.AppImage)

---

## How It Works

1. **Outline Server Installation**:
   The script uses the official Outline Manager installer to deploy the server and extract required credentials.

2. **Bot Configuration**:
   - Updates the `outline_bot.py` file with:
     - `OUTLINE_API_URL`
     - `OUTLINE_API_KEY`
     - `CERT_SHA256`
     - Admin IDs
     - Bot token

3. **System Service Setup**:
   Configures a systemd service (`outline_bot.service`) to run the bot persistently.

---

## Troubleshooting

### Issue: Bot Service Fails to Start
**Solution**:
1. Check the logs:
   ```bash
   journalctl -u outline_bot.service -n 50
   ```
2. Ensure all dependencies are installed:
   ```bash
   pip install -r /opt/outline_bot/requirements.txt
   ```

### Issue: Update Process Fails
**Solution**:
1. Run the update script manually:
   ```bash
   sudo bash /opt/outline_bot/update.sh
   ```
2. Check for errors in `/opt/outline_bot/update.log`.

---

## Uninstallation

To remove the Outline Server and bot:

1. Stop and disable the bot service:
   ```bash
   sudo systemctl stop outline_bot.service
   sudo systemctl disable outline_bot.service
   ```

2. Remove the service file:
   ```bash
   sudo rm /etc/systemd/system/outline_bot.service
   sudo systemctl daemon-reload
   ```

3. Delete installation files:
   ```bash
   sudo rm -rf /opt/outline outline_env users_data.json logs
   ```

---

## Support

For assistance, contact the 24/7 support team at:

📞 Telegram: [@irannetwork_co](https://t.me/irannetwork_co)

---

## Repository

You can access the repository and contribute at:

[Outline Server Installer on GitHub](https://github.com/mkh-python/outline-server-installer)

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## Contributions

Contributions are welcome! Feel free to submit issues or pull requests to improve this repository.
