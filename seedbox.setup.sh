#!/bin/bash

# --- Professional Seedbox Automation Script ---
# Idempotent, interactive, and permission-hardened.

set -e 

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "--- Starting Seedbox Deployment ---"

# 2. User Mapping & Permission Logic
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd)

if [[ -z "$EXISTING_USERS" ]]; then
    echo "No non-root users found. Creating 'seeduser'..."
    useradd -m -s /bin/bash seeduser
    SELECTED_USER="seeduser"
else
    echo "Existing users found: $EXISTING_USERS"
    read -p "Enter username to use [Default: seeduser]: " SELECTED_USER
    SELECTED_USER=${SELECTED_USER:-seeduser}
    if ! id "$SELECTED_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$SELECTED_USER"
        echo "Created user $SELECTED_USER."
    fi
fi

PUID=$(id -u "$SELECTED_USER")
PGID=$(id -g "$SELECTED_USER")
USER_HOME=$(eval echo "~$SELECTED_USER")
DOCKER_DIR="$USER_HOME/docker"
MEDIA_DIR="$USER_HOME/media"

# 3. Dependency Management
echo "Checking dependencies..."
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

if ! dpkg -l | grep -q docker-compose-plugin; then
    echo "Installing Docker Compose Plugin..."
    apt-get update && apt-get install -y docker-compose-plugin
fi

usermod -aG docker "$SELECTED_USER"

# 4. Interactive App Selection
declare -A APPS
declare -A PORTS=( 
    ["qbittorrent"]="8080" ["sonarr"]="8989" ["radarr"]="7878" 
    ["bazarr"]="6767" ["listenarr"]="4545" ["prowlarr"]="9696" ["jackett"]="9117" 
)

echo -e "\n--- Application Selection (Press Enter for Yes) ---"
for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    read -p "Install $app? [Y/n]: " choice
    choice=${choice:-y}
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        APPS[$app]=false
    else
        APPS[$app]=true
    fi
done

# 5. Directory Structure & Permission Prep
echo "Preparing directories..."
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR/downloads" "$MEDIA_DIR/tv" "$MEDIA_DIR/movies" "$MEDIA_DIR/music"

# Specific config folders for apps to prevent permission collisions
for app in "${!PORTS[@]}"; do
    mkdir -p "$DOCKER_DIR/$app"
done

# 6. Dynamic Docker Compose Generation
cat <<EOF > "$DOCKER_DIR/docker-compose.yml"
services:
EOF

# --- Container: qBittorrent ---
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

# --- Container: Listenarr ---
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

# Function for LinuxServer images
add_ls_container() {
    local name=$1
    local port=$2
    local volume=$3
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
      - $MEDIA_DIR/$volume:/$volume
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

# Finalize ownership before startup
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"

# 7. Deployment
echo -e "\nDeploying containers and cleaning orphans..."
cd "$DOCKER_DIR"
docker compose up -d --remove-orphans

# 8. Post-Deployment Intelligence
if [[ "${APPS[qbittorrent]}" == true ]]; then
    echo "Waiting for qBittorrent logs..."
    sleep 8
    QBIT_PASS=$(docker logs qbittorrent 2>&1 | grep "password" | awk '{print $NF}' | head -n 1)
    echo -e "\n--- qBittorrent Credentials ---"
    echo "Username: admin"
    echo "Password: ${QBIT_PASS:-[Check logs manually: docker logs qbittorrent]}"
fi

# 9. Status Dashboard
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -s --max-time 5 https://ifconfig.me || echo "N/A")

echo -e "\n--- Deployment Summary ---"
echo "Internal: http://$INTERNAL_IP"
echo "External: http://$EXTERNAL_IP"
echo "---------------------------"

for app in "qbittorrent" "sonarr" "radarr" "bazarr" "listenarr" "prowlarr" "jackett"; do
    if [[ "${APPS[$app]}" == true ]]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "not found")
        printf "%-12s : http://%s:%-5s [%s]\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}" "$STATUS"
    done
