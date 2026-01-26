#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

STEP_DELAY=2
MAX_WAIT=60

log()     { echo -e "\n🔹 $1"; }
success() { echo -e "✅ $1"; }
warn()    { echo -e "⚠️ $1"; }
fatal()   { echo -e "❌ $1"; exit 1; }

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

echo "🚀 Seedbox setup started"

[[ "$(id -u)" -ne 0 ]] && fatal "Please run as root"
success "Running as root"

############################
# USER
############################
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
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASS1" | chpasswd
    success "User created"
fi

USER_HOME="/home/$USERNAME"
DOCKER_DIR="$USER_HOME/docker"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

############################
# CLEAN INSTALL
############################
if [[ -f "$COMPOSE_FILE" ]]; then
    read -rp "Existing Docker setup found. Do CLEAN install? (y/n): " CLEAN
    if [[ "$CLEAN" == "y" ]]; then
        log "Removing old Docker setup..."
        compose -f "$COMPOSE_FILE" down || true
        rm -rf "$DOCKER_DIR"
        success "Clean install prepared"
    fi
fi

############################
# DOCKER
############################
log "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    apt update -y
    apt install -y docker.io docker-compose
fi
success "Docker installed"

log "Waiting for Docker daemon..."
for i in $(seq 1 $MAX_WAIT); do
    docker info >/dev/null 2>&1 && break
    sleep $STEP_DELAY
done || fatal "Docker daemon failed"
success "Docker daemon running"

############################
# APP SELECTION
############################
declare -A APPS
for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
    read -rp "Install $app? (y/n): " APPS[$app]
done

############################
# NETWORK
############################
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -fsSL https://api.ipify.org || echo "UNKNOWN")

############################
# COMPOSE FILE
############################
mkdir -p "$DOCKER_DIR"
chown -R "$USERNAME:$USERNAME" "$DOCKER_DIR"

PUID=$(id -u "$USERNAME")
PGID=$(id -g "$USERNAME")

cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

add() { echo "$1" >> "$COMPOSE_FILE"; }

[[ "${APPS[qbittorrent]}" == "y" ]] && add "
  qbittorrent:
    image: ghcr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=$PUID
      - PGID=$PGID
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

[[ "${APPS[sonarr]}" == "y" ]] && add "
  sonarr:
    image: ghcr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
    volumes:
      - $USER_HOME/sonarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8989:8989
    restart: unless-stopped
"

[[ "${APPS[radarr]}" == "y" ]] && add "
  radarr:
    image: ghcr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=$PUID
      - PGID=$PGID
    volumes:
      - $USER_HOME/radarr:/config
      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 7878:7878
    restart: unless-stopped
"

success "Docker Compose file created at $COMPOSE_FILE"

############################
# START
############################
log "Starting containers..."
compose -f "$COMPOSE_FILE" up -d
success "Containers started"

############################
# QB PASSWORD
############################
if [[ "${APPS[qbittorrent]}" == "y" ]]; then
    log "Waiting for qBittorrent credentials..."
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
echo "📊 Access URLs:"
print() {
  echo " - $1:"
  echo "     http://$INTERNAL_IP:$2"
  [[ "$EXTERNAL_IP" != "UNKNOWN" ]] && echo "     http://$EXTERNAL_IP:$2 ⚠️ open port"
}

[[ "${APPS[qbittorrent]}" == "y" ]] && print qbittorrent 8080
[[ -n "${QB_PASS:-}" ]] && echo -e "\n🔑 qBittorrent login → admin / $QB_PASS"

success "Seedbox setup complete 🎉"
