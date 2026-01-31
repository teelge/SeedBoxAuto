#!/bin/bash

# --- Professional Seedbox Automation Script ---
# Idempotent, interactive, and supports Clean Install.

set -e 

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "--- Seedbox Auto-Deployer ---"

# 2. User Mapping
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)

if [[ -z "$EXISTING_USERS" ]]; then
    SELECTED_USER="seeduser"
    [[ ! -d "/home/$SELECTED_USER" ]] && useradd -m -s /bin/bash "$SELECTED_USER"
else
    echo "Existing users found: $EXISTING_USERS"
    read -p "Enter username to use [Default: seeduser]: " SELECTED_USER
    SELECTED_USER=${SELECTED_USER:-seeduser}
    if ! id "$SELECTED_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$SELECTED_USER"
    fi
fi

PUID=$(id -u "$SELECTED_USER")
PGID=$(id -g "$SELECTED_USER")
USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 3. Clean Install Logic
if [ -d "$DOCKER_DIR" ]; then
    echo -e "\n[!] Existing configuration detected in $DOCKER_DIR"
    read -p "Perform a CLEAN INSTALL? (This deletes ALL data/configs!) [y/N]: " clean_choice
    clean_choice=${clean_choice:-n}
    
    if [[ "$clean_choice" =~ ^[Yy]$ ]]; then
        echo "Wiping existing deployment..."
        cd "$DOCKER_DIR" && docker compose down --rmi all -v --remove-orphans || true
        rm -rf "$DOCKER_DIR"
        rm -rf "$MEDIA_DIR"
        echo "Cleanup complete. Starting fresh install."
    else
        echo "Proceeding with update/reconfiguration..."
    fi
fi

# 4. Dependency Management
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

if ! dpkg -l | grep -q docker-compose-plugin; then
    apt-get update && apt-get install -y docker-compose-plugin
fi

usermod -aG docker "$SELECTED_USER"

# 5. Interactive App Selection
declare -A APPS
declare -A PORTS=( 
    ["qbittorrent"]="8080" ["sonarr"]="8989" ["radarr"]="7878" 
    ["bazarr"]="6767" ["listenarr"]="4545" ["prowlarr"]="9696" ["jackett"]="9117" 
)

echo -e "\n--- Application Selection (Press Enter for Yes) ---"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    read -p "Install $app? [Y/n]: " choice
    choice=${choice:-y}
    [[ "$choice" =~ ^[Nn]$ ]] && APPS[$app]=false || APPS[$app]=true
done

# 6. Directory Structure
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR/downloads" "$MEDIA_DIR/tv" "$MEDIA_DIR/movies" "$MEDIA_DIR/music"
for app in "${!PORTS[@]}"; do mkdir -p "$DOCKER_DIR/$app"; done

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
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: "$PUID:$PGID"
    environment:
      - LISTENARR_PUBLIC_URL=http://$(hostname -I | awk '{print $1}'):4545
    volumes:
      - $DOCKER_DIR/listenarr:/app/config
      - $MEDIA_DIR/music:/music
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
    environment: { PUID: $PUID, PGID: $PGID, TZ: UTC }
    volumes:
      - $DOCKER_DIR/$name:/config
      - $MEDIA_DIR/$vol:/$vol
      - $MEDIA_DIR/downloads:/downloads
    ports: [ "$port:$port" ]
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

# 8. Post-Deployment Info
if [[ "${APPS[qbittorrent]}" == true ]]; then
    echo "Grabbing qBittorrent password..."
    sleep 8
    QBIT_PASS=$(docker logs qbittorrent 2>&1 | grep "password" | awk '{print $NF}' | head -n 1)
    echo -e "\n--- qBittorrent --- \nUser: admin | Pass: ${QBIT_PASS:-Check Logs}"
fi

INTERNAL_IP=$(hostname -I | awk '{print $1}')
echo -e "\n--- Status Dashboard ---"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    if [[ "${APPS[$app]}" == true ]]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "offline")
        printf "%-12s : http://%s:%-5s [%s]\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}" "$STATUS"
    fi
done
