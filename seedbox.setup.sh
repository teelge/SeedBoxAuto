#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

echo "🚀 Seedbox setup started"

# -------------------------
# ROOT CHECK
# -------------------------
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Please run as root"
  exit 1
fi
echo "✅ Running as root"

# -------------------------
# USER SELECTION
# -------------------------
USERS=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)

USE_EXISTING="n"
if [[ -n "$USERS" ]]; then
  echo "Existing non-root users detected:"
  echo "$USERS"
  read -rp "Use an existing user? (y/n): " USE_EXISTING
fi

if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
  read -rp "Enter the username to use: " SEEDUSER
  id "$SEEDUSER" >/dev/null 2>&1 || { echo "❌ User not found"; exit 1; }
else
  read -rp "Enter new username: " SEEDUSER
  adduser "$SEEDUSER"
fi

USER_HOME=$(getent passwd "$SEEDUSER" | cut -d: -f6)
PUID=$(id -u "$SEEDUSER")
PGID=$(id -g "$SEEDUSER")

echo "👤 Using user: $SEEDUSER ($PUID:$PGID)"

# -------------------------
# PATHS
# -------------------------
COMPOSE_DIR="$USER_HOME/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
MEDIA_ROOT="$USER_HOME/media"

# -------------------------
# CLEAN INSTALL CHECK
# -------------------------
if [[ -f "$COMPOSE_FILE" ]]; then
  read -rp "Existing Docker setup found. CLEAN install? (y/n): " CLEAN
  if [[ "$CLEAN" =~ ^[Yy]$ ]]; then
    echo "🔹 Removing old Docker setup..."
    docker compose -f "$COMPOSE_FILE" down || true
    rm -rf "$COMPOSE_DIR"
    echo "✅ Clean install prepared"
  fi
fi

# -------------------------
# DOCKER INSTALL
# -------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "🔹 Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi

# Docker Compose (plugin preferred)
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "❌ Docker Compose not available"
  exit 1
fi

usermod -aG docker "$SEEDUSER"
echo "ℹ️  $SEEDUSER must log out and back in for Docker group access"

# -------------------------
# WAIT FOR DOCKER
# -------------------------
echo "🔹 Waiting for Docker daemon..."
until docker info >/dev/null 2>&1; do
  sleep 2
done
echo "✅ Docker running"

# -------------------------
# MEDIA FOLDERS (CRITICAL FIX)
# -------------------------
echo "🔹 Creating media folders..."

mkdir -p \
  "$MEDIA_ROOT/tv" \
  "$MEDIA_ROOT/movies" \
  "$MEDIA_ROOT/music" \
  "$MEDIA_ROOT/downloads"

chown -R "$PUID:$PGID" "$MEDIA_ROOT"
chmod -R 775 "$MEDIA_ROOT"

# -------------------------
# APP SELECTION
# -------------------------
declare -A INSTALL
for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
  read -rp "Install $app? (y/n): " INSTALL[$app]
done

mkdir -p "$COMPOSE_DIR"
chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"

# -------------------------
# COMPOSE HEADER
# -------------------------
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

# -------------------------
# SERVICE FUNCTION
# -------------------------
add_service () {
  local name="$1" image="$2" ports="$3" volumes="$4"

  cat >> "$COMPOSE_FILE" <<EOF
  $name:
    image: $image
    container_name: $name
    environment:
      PUID: $PUID
      PGID: $PGID
      TZ: UTC
    volumes:
$volumes
    ports:
      - "$ports"
    restart: unless-stopped

EOF
}

# -------------------------
# SERVICES
# -------------------------
[[ "${INSTALL[sonarr]}" =~ ^[Yy]$ ]] && add_service sonarr ghcr.io/linuxserver/sonarr:latest "8989:8989" "
      - $MEDIA_ROOT:/media
      - $USER_HOME/sonarr:/config"

[[ "${INSTALL[radarr]}" =~ ^[Yy]$ ]] && add_service radarr ghcr.io/linuxserver/radarr:latest "7878:7878" "
      - $MEDIA_ROOT:/media
      - $USER_HOME/radarr:/config"

[[ "${INSTALL[bazarr]}" =~ ^[Yy]$ ]] && add_service bazarr ghcr.io/linuxserver/bazarr:latest "6767:6767" "
      - $MEDIA_ROOT:/media
      - $USER_HOME/bazarr:/config"

[[ "${INSTALL[qbittorrent]}" =~ ^[Yy]$ ]] && add_service qbittorrent ghcr.io/linuxserver/qbittorrent:latest "8080:8080" "
      - $MEDIA_ROOT/downloads:/downloads
      - $USER_HOME/qbittorrent:/config"

[[ "${INSTALL[prowlarr]}" =~ ^[Yy]$ ]] && add_service prowlarr ghcr.io/linuxserver/prowlarr:latest "9696:9696" "
      - $USER_HOME/prowlarr:/config"

if [[ "${INSTALL[listenarr]}" =~ ^[Yy]$ ]]; then
cat >> "$COMPOSE_FILE" <<EOF
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: "$PUID:$PGID"
    volumes:
      - $USER_HOME/listenarr:/app/config
    ports:
      - "4545:4545"
    restart: unless-stopped

EOF
fi

[[ "${INSTALL[jackett]}" =~ ^[Yy]$ ]] && add_service jackett ghcr.io/linuxserver/jackett:latest "9117:9117" "
      - $USER_HOME/jackett:/config"

chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"

# -------------------------
# START
# -------------------------
echo "🔹 Starting containers..."
$COMPOSE -f "$COMPOSE_FILE" up -d
sleep 5

# -------------------------
# STATUS
# -------------------------
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -s https://api.ipify.org || echo "UNKNOWN")

echo
echo "📊 Running services:"
for c in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
  if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
    PORT=$(docker port "$c" | head -n1 | awk -F: '{print $2}')
    echo " - $c: http://$INTERNAL_IP:$PORT"
    [[ "$EXTERNAL_IP" != "UNKNOWN" ]] && echo "     External: http://$EXTERNAL_IP:$PORT ⚠️"
  fi
done

echo
echo "✅ Setup complete!"
echo "📁 Media root mounted in apps as: /media"
echo "⚠️  Do NOT use /root inside WebUIs"
