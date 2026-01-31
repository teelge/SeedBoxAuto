#!/bin/bash

# --- SeedBoxAuto Uninstaller ---
# Warning: This will delete ALL media and configurations!

set -e

# 1. Identify the user and home directory
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)
echo "Found users: $EXISTING_USERS"
read -p "Enter the username used for the install [Default: seeduser]: " SELECTED_USER
SELECTED_USER=${SELECTED_USER:-seeduser}

USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

echo "------------------------------------------------"
echo "⚠️  WARNING: TOTAL DATA DELETION ⚠️"
echo "This will remove all apps, configs, and MEDIA."
echo "------------------------------------------------"
read -p "Are you absolutely sure? (type 'DELETE' to confirm): " confirm

if [[ "$confirm" != "DELETE" ]]; then
    echo "Uninstall cancelled."
    exit 1
fi

# 2. Shut down Docker containers
if [ -d "$DOCKER_DIR" ]; then
    echo "[*] Stopping and removing containers..."
    cd "$DOCKER_DIR"
    # --rmi all: removes the images
    # -v: removes the named volumes
    # --remove-orphans: cleans up anything left over
    docker compose down --rmi all -v --remove-orphans || true
fi

# 3. Remove Directories
echo "[*] Deleting application and media folders..."
rm -rf "$DOCKER_DIR"
rm -rf "$MEDIA_DIR"

# 4. Cleanup Docker System (Optional)
read -p "Clean up unused Docker networks/cache? [y/N]: " docker_clean
if [[ "$docker_clean" =~ ^[Yy]$ ]]; then
    echo "[*] Pruning Docker system..."
    docker system prune -f
fi

echo "------------------------------------------------"
echo "✅ SUCCESS: SeedBoxAuto has been removed."
echo "------------------------------------------------"