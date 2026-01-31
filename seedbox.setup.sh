#!/bin/bash

# --- SeedboxAuto: The Ultimate Media Stack Deployer ---
# Author: teelge
# Features: Idempotent, Multi-Arch (x86/ARM), Interactive, Default=Y

set -e 

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

# --- NEW: Architecture Detection ---
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

# 2. User Mapping & Permission Logic
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
    read -p "Perform a CLEAN INSTALL? (This wipes ALL configs & media!) [y/N (default: N)]: " clean_choice
    clean_choice=${clean_choice:-n}
    
    if [[ "$clean_choice" =~ ^[Yy]$ ]]; then
        echo "Wiping existing deployment..."
        cd "$DOCKER_DIR" && docker compose down --rmi all -v --remove-orphans || true
        rm -rf "$DOCKER_DIR"
        rm -rf "$MEDIA_DIR"
        echo "Cleanup complete. Starting fresh install..."
    else
        echo "Proceeding with update/reconfiguration..."
    fi
fi

# 4. Dependency Management (Universal OS Check)
echo "Verifying Docker installation..."
if ! command -v docker &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm docker docker-compose
        systemctl enable --now docker
    fi
fi

# Ensure docker-compose-plugin is present (Required for 'docker compose' command)
if ! docker compose version &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y docker-compose-plugin
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
echo "--- Application Selection (Press Enter to accept ALL defaults) ---"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    read -p "Install $app? [Y/n (default: Y)]: " choice
    choice=${choice:-y}
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        APPS[$app]=false
    else
        APPS[$app]=true
    fi
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

if [[ "${APPS[qbittorrent]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $DOCKER_DIR/qbittorrent:/config
      - $MEDIA_DIR/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped
EOF
fi

if [[ "${APPS[listenarr]}" == true ]]; then
    # Note: Using standard linuxserver/airsonic-madsonic style logic or specific multi-arch images
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: "$PUID:$PGID"
    environment:
      - LISTENARR_PUBLIC_URL=http://$(hostname -I | awk '{print $1}'):4545
    volumes:
      - $DOCKER_DIR/listenarr:/app/config
      - $MEDIA_DIR/audio:/audio
    ports:
      - 4545:4545
    restart: unless-stopped
EOF
fi

add_ls_container() {
    local name=$1 port=$2 vol=$3
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  $name:
    image: lscr.io/linuxserver/$name:latest
    container_name: $name
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $DOCKER_DIR/$name:/config
      - $MEDIA_DIR/$vol:/$vol
      - $MEDIA_DIR/downloads:/downloads
    ports:
      - $port:$port
    restart: unless-stopped
EOF
}

[[ "${APPS[sonarr]}" == true ]] && add_ls_container "sonarr" "8989" "tv"
[[ "${APPS[radarr]}" == true ]] && add_ls_container "radarr" "7878" "movies"
[[ "${APPS[bazarr]}" == true ]] && add_ls_container "bazarr" "6767" "movies"
[[ "${APPS[prowlarr]}" == true ]] && add_ls_container "prowlarr" "9696" "downloads"
[[ "${APPS[jackett]}" == true ]] && add_ls_container "jackett" "9117" "downloads"

# Permissions and Startup
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"
cd "$DOCKER_DIR"
docker compose up -d --remove-orphans

# 8. Post-Deployment Intelligence
if [[ "${APPS[qbittorrent]}" == true ]]; then
    echo ""
    echo "Retrieving initial qBittorrent credentials..."
    sleep 10
    QBIT_PASS=$(docker logs qbittorrent 2>&1 | grep "password" | awk '{print $NF}' | head -n 1)
    echo "--- qBittorrent ---"
    echo "Username: admin"
    echo "Password: ${QBIT_PASS:-Check 'docker logs qbittorrent'}"
fi

# 9. Status Dashboard
INTERNAL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "------------------------------------------------"
echo "           ✅ DEPLOYMENT SUMMARY                "
echo "------------------------------------------------"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    if [[ "${APPS[$app]}" == true ]]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "not found")
        printf "%-12s : http://%s:%-5s [%s]\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}" "$STATUS"
    fi
done
echo "------------------------------------------------"
