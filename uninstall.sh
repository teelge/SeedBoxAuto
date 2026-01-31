#!/bin/bash

# --- SeedBoxAuto: Total Cleanup Script ---
set -e

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo."
   exit 1
fi

echo "------------------------------------------------"
echo "        🗑️  SEEDBOXAUTO UNINSTALLER            "
echo "------------------------------------------------"

# 2. Identify User
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)
read -p "Enter the username used during install [Default: seeduser]: " SELECTED_USER
SELECTED_USER=${SELECTED_USER:-seeduser}

USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 3. Final Warning (Enter = Yes)
echo ""
echo "⚠️  DANGER: This will delete ALL media, configs, and containers."
# We use -i "Y" to pre-fill or just check if empty
read -p "Are you sure you want to wipe everything? [Y/n]: " confirm

# THE FIX: If the user hits enter, $confirm is empty. This line makes it "y"
confirm="${confirm:-y}"

# Check if the answer is "y" or "Y"
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "[!] Proceeding with full cleanup..."
else
    echo "Cleanup aborted."
    exit 1
fi

# 4. Stop and Wipe Docker
if [ -d "$DOCKER_DIR" ]; then
    echo "[*] Shutting down services and removing images..."
    cd "$DOCKER_DIR"
    docker compose down --rmi all -v --remove-orphans || true
fi

# 5. Remove Folders
echo "[*] Removing data folders..."
rm -rf "$DOCKER_DIR"
rm -rf "$MEDIA_DIR"

echo "------------------------------------------------"
echo "✅ CLEANUP COMPLETE"
echo "------------------------------------------------"
