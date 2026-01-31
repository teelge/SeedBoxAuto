#!/bin/bash

# --- Seedbox Automation Script ---
# Idempotent, interactive, and professional.

set -e # Exit on error

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "--- Starting Seedbox Deployment ---"

# 2. User Mapping & Permission Logic
EXISTING_USERS=$(awk -F' ' '{ if ($3 >= 1000 && $3 != 65534) print $1 }' /etc/passwd)

if [[ -z "$EXISTING_USERS" ]]; then
    echo "No non-root users found. Creating 'seeduser'..."
    useradd -m -s /bin/bash seeduser
    SELECTED_USER="seeduser"
else
    echo "Existing users found: $EXISTING_USERS"
    read -p "Enter username to use (or type 'seeduser' to create new): " SELECTED_USER
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
    ["bazarr"]="6767" ["lidarr"]="8686" ["prowlarr"]="9696" ["jackett"]="9117" 
)

echo "--- Application Selection ---"
for app in "${!PORTS[@]}"; do
    read -p "Install $app? (Y/n): " choice
    [[ "$choice" =~ ^[Nn]$ ]] && APPS[$app]=false || APPS[$app]=true
done

# 5. Directory Structure
mkdir -p "$DOCKER_DIR" "$MEDIA_DIR/downloads" "$MEDIA_DIR/tv" "$MEDIA_DIR/movies" "$MEDIA_DIR/music"
chown -R "$PUID:$PGID" "$DOCKER_DIR" "$MEDIA_DIR"

# 6. Dynamic Docker Compose Generation
cat <<EOF > "$DOCKER_DIR/docker-compose.yml"
services:
EOF

# Append services based on selection
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
      - $MEDIA_DIR/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped
EOF
fi

# Function to add LinuxServer containers easily
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
[[ "${APPS[lidarr]}" == true ]] && add_ls_container "lidarr" "8686" "music"
[[ "${APPS[prowlarr]}" == true ]] && add_ls_container "prowlarr" "9696" "downloads"
[[ "${APPS[jackett]}" == true ]] && add_ls_container "jackett" "9117" "downloads"

chown "$PUID:$PGID" "$DOCKER_DIR/docker-compose.yml"

# 7. Post-Deployment Intelligence
echo "Starting containers..."
cd "$DOCKER_DIR"
docker compose up -d

# Scrape qBittorrent password
if [[ "${APPS[qbittorrent]}" == true ]]; then
    echo "Waiting for qBittorrent to generate credentials..."
    sleep 5
    QBIT_PASS=$(docker logs qbittorrent 2>&1 | grep "password" | awk '{print $NF}')
    echo "--- qBittorrent Security ---"
    echo "Temporary Password: $QBIT_PASS"
    echo "Username: admin"
fi

# 8. Status Dashboard
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -s https://ifconfig.me)

echo -e "\n--- Deployment Summary ---"
echo "Internal: http://$INTERNAL_IP"
echo "External: http://$EXTERNAL_IP"
echo "---------------------------"

for app in "${!APPS[@]}"; do
    if [[ "${APPS[$app]}" == true ]]; then
        printf "%-12s : http://%s:%s\n" "$app" "$INTERNAL_IP" "${PORTS[$app]}"
    fi
done
