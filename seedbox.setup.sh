#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################
# CONFIG
############################
STEP_DELAY=2
MAX_WAIT=60

############################
# LOGGING
############################
log()     { echo -e "\n🔹 $1"; }
success() { echo -e "✅ $1"; }
warn()    { echo -e "⚠️ $1"; }
fatal()   { echo -e "❌ $1"; exit 1; }

############################
# ROOT CHECK
############################
echo "🚀 Seedbox setup started"

if [[ "$(id -u)" -ne 0 ]]; then
    fatal "Please run as root"
fi
success "Running as root"

############################
# USER SELECTION
############################
log "Checking existing users..."

USERS=$(awk -F: '$3 >= 1000 && $1 != "nobody"' /etc/passwd || true)

if [[ -n "$USERS" ]]; then
    echo "Existing non-root users detected:"
    echo "$USERS"
    read -rp "Do you want to use an existing user? (y/n): " use_existing
else
    use_existing="n"
fi

if [[ "$use_existing" == "y" ]]; then
    read -rp "Enter the username to use: " USERNAME
    id "$USERNAME" >/dev/null 2>&1 || fatal "User does not exist"
else
    read -rp "Enter the new username: " USERNAME
    read -rsp "Enter password for $USERNAME: " PASS1; echo
    read -rsp "Retype password: " PASS2; echo
    [[ "$PASS1" != "$PASS2" ]] && fatal "Passwords do not match"

    log "Creating user '$USERNAME'..."
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASS1" | chpasswd
    success "User '$USERNAME' created successfully"
fi

USER_HOME="/home/$USERNAME"
DOCKER_DIR="$USER_HOME/docker"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

############################
# CLEAN INSTALL
############################
if [[ -d "$DOCKER_DIR" ]]; then
    read -rp "Existing Docker setup found. Do CLEAN install? (y/n): " CLEAN
    if [[ "$CLEAN" == "y" ]]; then
        log "Removing old Docker setup..."
        docker compose -f "$COMPOSE_FILE" down || true
        rm -rf "$DOCKER_DIR"
        success "Clean install prepared"
    fi
fi

############################
# DOCKER INSTALL
############################
log "Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    apt update -y
    apt install -y docker.io docker-compose
fi

success "Docker installed"

log "Waiting for Docker daemon..."
for i in $(seq 1 $MAX_WAIT); do
    docker info >/dev/null 2>&1 && break
    sleep $STEP_DELAY
done || fatal "Docker daemon did not start"

success "Docker daemon running"

############################
# APP SELECTION
############################
declare -A APPS
for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
    read -rp "Install $app? (y/n): " choice
    APPS[$app]=$choice
done

############################
# NETWORK INFO
############################
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -fsSL https://api.ipify.org || echo "UNKNOWN")

############################
# DOCKER COMPOSE GENERATION
############################
log "Generating Docker Compose file..."

mkdir -p "$DOCKER_DIR"
chown -R "$USERNAME:$USERNAME" "$DOCKER_DIR"

PUID=$(id -u "$USERNAME")
PGID=$(id -g "$USERNAME")

cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

add_service() {
    echo "$1" >> "$COMPOSE_FILE"
}

[[ "${APPS[sonarr]}" == "y" ]] && add_service "
  sonarr:
    image: ghcr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/sonarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8989:8989
    restart: unless-stopped
"

[[ "${APPS[radarr]}" == "y" ]] && add_service "
  radarr:
    image: ghcr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/radarr:/config
      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 7878:7878
    restart: unless-stopped
"

[[ "${APPS[qbittorrent]}" == "y" ]] && add_service "
  qbittorrent:
    image: ghcr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
      - WEBUI_PORT=8080
    volumes:
      - $USER_HOME/qbittorrent:/config
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped
"

[[ "${APPS[bazarr]}" == "y" ]] && add_service "
  bazarr:
    image: ghcr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/bazarr:/config
      - $USER_HOME/media:/media
    ports:
      - 6767:6767
    restart: unless-stopped
"

[[ "${APPS[prowlarr]}" == "y" ]] && add_service "
  prowlarr:
    image: ghcr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/prowlarr:/config
    ports:
      - 9696:9696
    restart: unless-stopped
"

[[ "${APPS[listenarr]}" == "y" ]] && add_service "
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: $PUID:$PGID
    environment:
      - LISTENARR_PUBLIC_URL=http://$EXTERNAL_IP:4545
    volumes:
      - $USER_HOME/listenarr:/app/config
    ports:
      - 4545:4545
    restart: unless-stopped
"

[[ "${APPS[jackett]}" == "y" ]] && add_service "
  jackett:
    image: ghcr.io/linuxserver/jackett:latest
    container_name: jackett
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/jackett:/config
    ports:
      - 9117:9117
    restart: unless-stopped
"

success "Docker Compose file created at $COMPOSE_FILE"

############################
# START CONTAINERS
############################
log "Starting containers..."
docker compose -f "$COMPOSE_FILE" up -d
success "Containers started"

############################
# WAIT FOR CONTAINERS
############################
wait_container() {
    for i in $(seq 1 $MAX_WAIT); do
        docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true && return 0
        sleep $STEP_DELAY
    done
    return 1
}

for c in "${!APPS[@]}"; do
    [[ "${APPS[$c]}" == "y" ]] && wait_container "$c" && success "$c running"
done

############################
# QB PASSWORD
############################
if [[ "${APPS[qbittorrent]}" == "y" ]]; then
    log "Waiting for qBittorrent WebUI password..."
    QB_PASS=""
    for i in $(seq 1 $MAX_WAIT); do
        QB_PASS=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password is provided for this session: \K\w+' | tail -n1)
        [[ -n "$QB_PASS" ]] && break
        sleep $STEP_DELAY
    done
fi

############################
# SUMMARY
############################
echo
echo "📊 Summary of running seedbox apps:"

print_url() {
    echo " - $1 : UP"
    echo "     Internal URL: http://$INTERNAL_IP:$2"
    [[ "$EXTERNAL_IP" != "UNKNOWN" ]] && \
    echo "     External URL: http://$EXTERNAL_IP:$2 ⚠️ Make sure port is open"
}

[[ "${APPS[sonarr]}" == "y" ]] && print_url sonarr 8989
[[ "${APPS[radarr]}" == "y" ]] && print_url radarr 7878
[[ "${APPS[qbittorrent]}" == "y" ]] && print_url qbittorrent 8080
[[ "${APPS[bazarr]}" == "y" ]] && print_url bazarr 6767
[[ "${APPS[prowlarr]}" == "y" ]] && print_url prowlarr 9696
[[ "${APPS[listenarr]}" == "y" ]] && print_url listenarr 4545
[[ "${APPS[jackett]}" == "y" ]] && print_url jackett 9117

if [[ -n "${QB_PASS:-}" ]]; then
    echo
    echo "🔑 qBittorrent WebUI credentials:"
    echo "   Username: admin"
    echo "   Password: $QB_PASS"
    echo "⚠️ Change this password after login"
fi

echo
success "Seedbox setup complete 🎉"
