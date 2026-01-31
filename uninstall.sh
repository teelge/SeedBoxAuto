#!/bin/bash
# SeedBoxAuto Uninstaller - Bulletproof Version

echo "Checking for root permissions..."
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo."
   exit 1
fi

# Identify User
SELECTED_USER=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd | head -n 1)
read -p "Enter the username used during install [Default: $SELECTED_USER]: " INPUT_USER
SELECTED_USER=${INPUT_USER:-$SELECTED_USER}

USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

echo "⚠️  Wiping everything for user: $SELECTED_USER"
read -p "Are you sure? [Y/n]: " confirm
confirm="${confirm:-y}"

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Only try to enter the directory if it exists
    if [ -d "$DOCKER_DIR" ]; then
        echo "[*] Removing Docker containers..."
        cd "$DOCKER_DIR" && docker compose down --rmi all -v --remove-orphans || true
    fi

    echo "[*] Cleaning up folders..."
    rm -rf "$DOCKER_DIR"
    rm -rf "$MEDIA_DIR"
    echo "✅ Done!"
else
    echo "Aborted."
fi
