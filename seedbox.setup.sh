#!/bin/bash

# --- SeedboxAuto: The Ultimate Media Stack Deployer (VERBOSE VERSION) ---
set -e 

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

# Architecture Detection
ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64|arm64) ARCH_TYPE="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "------------------------------------------------"
echo "        🚀 STARTING SEEDBOXAUTO DEPLOY          "
echo "        System: $ARCH ($ARCH_TYPE)              "
echo "------------------------------------------------"

# 2. User Mapping
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)

if [[ -z "$EXISTING_USERS" ]]; then
    SELECTED_USER="seeduser"
    [[ ! -d "/home/$SELECTED_USER" ]] && useradd -m -s /bin/bash "$SELECTED_USER"
else
    echo "Found existing users: $EXISTING_USERS"
    read -p "Enter username to use [Default: seeduser]: " SELECTED_USER
    SELECTED_USER=${SELECTED_USER:-seeduser}
    if ! id "$SELECTED_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$SELECTED_USER"
        echo "Created new user: $SELECTED_USER"
    fi
fi

PUID=$(id -u "$SELECTED_USER")
PGID=$(id -g "$SELECTED_USER")
USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 3. Clean Install Logic
if [ -d "$DOCKER_DIR" ]; then
    echo ""
    echo "[!] WARNING: Existing configuration detected in $DOCKER_DIR"
    read -p "Perform a CLEAN INSTALL? [y/N]: " clean_choice
    clean_choice=${clean_choice:-n}
    
    if [[ "$clean_choice" =~ ^[Yy]$ ]]; then
        echo "Wiping existing deployment..."
        cd "$DOCKER_DIR" && docker compose down --rmi all -v --remove-orphans || true
        rm -rf "$DOCKER_DIR"
        rm -rf "$MEDIA_DIR"
    fi
fi

# 4. Dependency Management (VERBOSITY ADDED HERE)
echo "Verifying Docker installation..."
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Starting official installer with progress..."
    if command -v apt-get &> /dev/null; then
        # Removed the 'sh -s -- --quiet' logic to show full install progress
        curl -fsSL https://get.docker.com | sh 
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm docker docker-compose
        systemctl enable --now docker
    fi
fi

if ! docker compose version &> /dev/null; then
    echo "Installing Docker Compose Plugin..."
    if command -v apt-get &> /dev/null; then
        apt-get update # Removed -qq
        apt-get install -y docker-compose-plugin
    fi
fi

usermod -aG docker "$SELECTED_USER"

# 5. Interactive App Selection
declare -A APPS
declare -A PORTS=( 
    ["qbittorrent"]="8080" ["sonarr"]="8989" ["radarr"]="7878" 
    ["bazarr"]="6767" ["listenarr"]="4545" ["prowlarr"]="9696" ["jackett"]="9117" 
)

echo ""
echo "--- Application Selection ---"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    read -p "Install $app? [Y/n]: " choice
    choice=${choice:-y}
    [[ "$choice" =~ ^[Nn]$ ]] && APPS[$app]=false || APPS[$app]=true
done

# 6. Directory Structure
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR/downloads" "$MEDIA_DIR/tv" "$MEDIA_DIR/movies" "$MEDIA_DIR/audio"
for app in "${!PORTS[@]}"; do
    mkdir -p "$DOCKER_DIR/$app"
done

# 7. Dynamic Docker Compose Generation
cat <<EOF > "$DOCKER_DIR/docker-compose.yml"
services:
EOF

# (Logic for adding containers is same as your script...)
# [Truncated for brevity, but keep your existing app logic here]

# 8. Startup (SHOWING PULL PROGRESS)
echo "Pulling images and starting containers..."
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"
cd "$DOCKER_DIR"
# This will now show the download progress bars for every image
docker compose up -d --remove-orphans

# 9. Status Dashboard
INTERNAL_IP=$(hostname -I | awk '{print $1}')
echo "------------------------------------------------"
echo "            ✅ DEPLOYMENT SUMMARY               "
echo "------------------------------------------------"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    if [[ "${APPS[$app]}" == true ]]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "not found")
        printf "%-12s : http://%s:%-5s [%s]\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}" "$STATUS"
    fi
done
