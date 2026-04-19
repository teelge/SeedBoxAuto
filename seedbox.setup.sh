#!/bin/bash

# --- SeedboxAuto: Full Version with Status & Path Fixes ---
set -u

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "------------------------------------------------"
echo "         🚀 STARTING SEEDBOXAUTO DEPLOY          "
echo "------------------------------------------------"

# 2. User Setup
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
    fi
fi

PUID=$(id -u "$SELECTED_USER")
PGID=$(id -g "$SELECTED_USER")
USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 4. Dependencies
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi
groupadd -f docker
usermod -aG docker "$SELECTED_USER"

# 5. App Selection
declare -A APPS
declare -A PORTS=( 
    ["qbittorrent"]="8080" ["sonarr"]="8989" ["radarr"]="7878" 
    ["bazarr"]="6767" ["listenarr"]="4545" ["prowlarr"]="9696" 
    ["jackett"]="9117" ["jellyfin"]="8096" ["flaresolverr"]="8191"
    ["lidarr"]="8686" ["lazylibrarian"]="5299" ["mylar3"]="8090"
    ["plex"]="32400" ["audiobookshelf"]="8000"
)

APP_ORDER=("qbittorrent" "prowlarr" "flaresolverr" "sonarr" "radarr" "lidarr" "bazarr" "lazylibrarian" "mylar3" "listenarr" "jackett" "jellyfin" "plex" "audiobookshelf")

echo ""
echo "--- Application Selection ---"
for app in "${APP_ORDER[@]}"; do
    read -p "Install $app? [Y/n]: " choice
    choice=${choice:-y}
    [[ "$choice" =~ ^[Nn]$ ]] && APPS[$app]=false || APPS[$app]=true
done

# 6. Directories
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR"/{downloads,tv,movies,audio,music,books,comics,audiobooks,podcasts}
for app in "${APP_ORDER[@]}"; do 
    mkdir -p "$DOCKER_DIR/$app"
done

# 7. Compose Generation
cat <<EOF > "$DOCKER_DIR/docker-compose.yml"
services:
EOF

add_ls_container() {
    local name=$1 port=$2 img=${3:-lscr.io/linuxserver/$1:latest}
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  $name:
    image: $img
    container_name: $name
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $DOCKER_DIR/$name:/config
      - $MEDIA_DIR:/data
    ports:
      - $port:$port
    restart: unless-stopped
EOF
}

# --- Specific App Definitions ---
if [[ "${APPS[qbittorrent]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - $DOCKER_DIR/qbittorrent:/config
      - $MEDIA_DIR:/data
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped
EOF
fi

[[ "${APPS[sonarr]}" == true ]] && add_ls_container "sonarr" "8989"
[[ "${APPS[radarr]}" == true ]] && add_ls_container "radarr" "7878"
[[ "${APPS[bazarr]}" == true ]] && add_ls_container "bazarr" "6767"
[[ "${APPS[prowlarr]}" == true ]] && add_ls_container "prowlarr" "9696"
[[ "${APPS[jackett]}" == true ]] && add_ls_container "jackett" "9117"
[[ "${APPS[lidarr]}" == true ]] && add_ls_container "lidarr" "8686"
[[ "${APPS[lazylibrarian]}" == true ]] && add_ls_container "lazylibrarian" "5299"
[[ "${APPS[mylar3]}" == true ]] && add_ls_container "mylar3" "8090"

if [[ "${APPS[plex]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    network_mode: host
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - VERSION=docker
    volumes:
      - $DOCKER_DIR/plex:/config
      - $MEDIA_DIR:/data
    restart: unless-stopped
EOF
fi

if [[ "${APPS[audiobookshelf]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    environment:
      - AUDIOBOOKSHELF_UID=$PUID
      - AUDIOBOOKSHELF_GID=$PGID
    volumes:
      - $DOCKER_DIR/audiobookshelf/config:/config
      - $DOCKER_DIR/audiobookshelf/metadata:/metadata
      - $MEDIA_DIR/audiobooks:/audiobooks
      - $MEDIA_DIR/podcasts:/podcasts
    ports:
      - 8000:80
    restart: unless-stopped
EOF
fi

if [[ "${APPS[flaresolverr]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    ports:
      - 8191:8191
    restart: unless-stopped
EOF
fi

if [[ "${APPS[listenarr]}" == true ]]; then
    cat <<EOF >> "$DOCKER_DIR/docker-compose.yml"
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
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

if [[ "${APPS[jellyfin]}" == true ]]; then
    add_ls_container "jellyfin" "8096"
    [[ -d /dev/dri ]] && echo "    devices: [\"/dev/dri:/dev/dri\"]" >> "$DOCKER_DIR/docker-compose.yml"
fi

# 8. Permissions and Execution
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"
chmod -R 775 "$MEDIA_DIR"
cd "$DOCKER_DIR"

echo ""
echo "--- 📦 PULLING IMAGES ---"
docker compose pull

echo ""
echo "--- 🚀 STARTING CONTAINERS ---"
docker compose up -d --remove-orphans

# 9. Smart Summary & Info Extraction
echo ""
echo "------------------------------------------------"
echo "            ✅ DEPLOYMENT SUMMARY               "
echo "------------------------------------------------"
INTERNAL_IP=$(hostname -I | awk '{print $1}')

if [[ "${APPS[qbittorrent]}" == true ]]; then
    echo "Retrieving qBittorrent password..."
    QBIT_PASS=""
    for i in {1..10}; do
        QBIT_PASS=$(docker logs qbittorrent 2>&1 | grep "password" | awk '{print $NF}' | head -n 1)
        [[ ! -z "$QBIT_PASS" ]] && break
        sleep 2
    done
    echo "qBittorrent: admin | ${QBIT_PASS:-Check 'docker logs qbittorrent'}"
    echo "URL: http://$INTERNAL_IP:8080"
    echo "IMPORTANT: Set qBit Download Path to: /data/downloads"
    echo "------------------------------------------------"
fi

for app in "${APP_ORDER[@]}"; do
    if [[ "${APPS[$app]}" == true ]]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "not found")
        printf "%-15s : http://%s:%-5s [%s]\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}" "$STATUS"
    fi
done
echo "------------------------------------------------"
echo "------------------------------------------------"
echo "   CHANGE qBittorrent Password in UI Setting!!  "
echo "------------------------------------------------"
