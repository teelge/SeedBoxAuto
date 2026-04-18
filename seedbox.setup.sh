#!/bin/bash

# --- SeedboxAuto: Fixed Paths & Permissions ---
# Features: Unified /data paths, Plex & Audiobookshelf, Visible Pull

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
# Ensure user is in docker group
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
# CRITICAL: We ensure downloads is a SUBFOLDER of /data so hardlinks work
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR"/{downloads,tv,movies,audio,music,books,comics,audiobooks,podcasts}
for app in "${APP_ORDER[@]}"; do 
    mkdir -p "$DOCKER_DIR/$app"
done

# 7. Compose Generation
cat <<EOF > "$DOCKER_DIR/docker-compose.yml"
services:
EOF

# Standard LinuxServer template
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

# Specific fix for qBittorrent to use the same /data mount
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

# --- Specialty: Plex ---
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

# --- Specialty: Audiobookshelf ---
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

# --- Specialty: Others ---
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
    if [[ -d /dev/dri ]]; then
       sed -i "/jellyfin:/a \    devices:\n      - /dev/dri:/dev/dri" "$DOCKER_DIR/docker-compose.yml"
    fi
fi

# 8. Permissions and Start
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"
chmod -R 775 "$MEDIA_DIR"
cd "$DOCKER_DIR"

echo "--- 📦 PULLING IMAGES ---"
docker compose pull

echo "--- 🚀 STARTING CONTAINERS ---"
docker compose up -d --remove-orphans

# 9. Summary
echo "------------------------------------------------"
echo "            ✅ DEPLOYMENT COMPLETE              "
echo "------------------------------------------------"
INTERNAL_IP=$(hostname -I | awk '{print $1}')

echo "IMPORTANT: In qBittorrent Web UI, set your download path to: /data/downloads"
echo "In Sonarr/Radarr, set your root folder to: /data/tv or /data/movies"
echo "------------------------------------------------"
