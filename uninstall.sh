#!/bin/bash

# --- SeedBoxAuto: Total Cleanup Script ---
# Author: teelge
# This script wipes the containers, images, and media folders.

set -e

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo: sudo bash uninstall.sh"
   exit 1
fi

echo "------------------------------------------------"
echo "        🗑️  SEEDBOXAUTO UNINSTALLER            "
echo "------------------------------------------------"

# 2. Identify User
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)

if [[ -z "$EXISTING_USERS" ]]; then
    SELECTED_USER="seeduser"
else
    echo "Found existing users: $EXISTING_USERS"
    read -p "Enter the username used during install [Default: seeduser]: " SELECTED_USER
    SELECTED_USER=${SELECTED_USER:-seeduser}
fi

USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 3. Final Warning (Default is YES)
echo ""
echo "⚠️  DANGER: This will delete ALL media, configs, and containers."
read -p "Are you sure you want to wipe everything? [Y/n]: " confirm
confirm=${confirm:-y} # This makes Enter = Yes

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cleanup aborted."
    exit 1
fi

echo "[!] Proceeding with full cleanup..."

# 4. Stop and Wipe Docker
if [ -d "$DOCKER_DIR" ]; then
    echo "[*] Shutting down services and removing images..."
    cd "$DOCKER_DIR"
    # Stop containers and remove volumes/images
    docker compose down --rmi all -v --remove-orphans || true
else
    echo "[!] Docker directory not found at $DOCKER_DIR. Skipping Docker wipe."
fi

# 5. Remove Folders
echo "[*] Removing data folders at $DOCKER_DIR and $MEDIA_DIR..."
rm -rf "$DOCKER_DIR"
rm -rf "$MEDIA_DIR"

echo "------------------------------------------------"
echo "✅ CLEANUP COMPLETE"
echo "All SeedBoxAuto files have been removed."
echo "------------------------------------------------"
