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

# 3. Final Warning
echo ""
echo "⚠️  DANGER: This will delete:"
echo "   - All Docker Containers (qBit, Sonarr, etc.)"
echo "   - All App Configurations"
echo "   - ALL DOWNLOADED MEDIA ($MEDIA_DIR)"
echo ""
read -p "Are you sure? Type 'CONFIRM' to proceed: " final_check

if [[ "$final_check" != "CONFIRM" ]]; then
    echo "Cleanup aborted."
    exit 1
fi

# 4. Stop and Wipe Docker
if [ -d "$DOCKER_DIR" ]; then
    echo "[*] Shutting down services and removing images..."
    cd "$DOCKER_DIR"
    docker compose down --rmi all -v --remove-orphans || true
else
    echo "[!] Docker directory not found at $DOCKER_DIR"
fi

# 5. Remove Folders
echo "[*] Removing data folders..."
rm -rf "$DOCKER_DIR"
rm -rf "$MEDIA_DIR"

echo "------------------------------------------------"
echo "✅ CLEANUP COMPLETE"
echo "All SeedBoxAuto files have been removed."
echo "------------------------------------------------"
