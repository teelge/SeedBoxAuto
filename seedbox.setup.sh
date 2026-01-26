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

# -------------------------
# USER SELECTION
# -------------------------
USERS=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
USE_EXISTING="n"

if [[ -n "$USERS" ]]; then
  echo "Existing users:"
  echo "$USERS"
  read -rp "Use existing user? (y/n): " USE_EXISTING
fi

if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
  read -rp "Username: " SEEDUSER
  id "$SEEDUSER" >/dev/null 2>&1 || exit 1
else
  read -rp "New username: " SEEDUSER
  adduser "$SEEDUSER"
fi

USER_HOME=$(getent passwd "$SEEDUSER" | cut -d: -f6)
PUID=$(id -u "$SEEDUSER")
PGID=$(id -g "$SEEDUSER")

# -------------------------
# PATHS
# -------------------------
COMPOSE_DIR="$USER_HOME/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
MEDIA_ROOT="$USER_HOME/media"

# -------------------------
# CLEAN INSTALL
# -------------------------
if [[ -f "$COMPOSE_FILE" ]]; then
  read -rp "Existing install found. CLEAN install? (y/n): " CLEAN
  if [[ "$CLEAN" =~ ^[Yy]$ ]]; then
    docker compose -f "$COMPOSE_FILE" down || true
    rm -rf "$COMPOSE_DIR"
  fi
fi

# -------------------------
# DOCKER
# -------------------------
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
else
  COMPOSE="docker-compose"
fi

usermod -aG docker "$SEEDUSER"

until docker info >/dev/null 2>&1; do sleep 2; done

# -------------------------
# MEDIA FOLDERS
# -------------------------
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

# -------------------------
# RESET CONFIGS (NO PASSWORD GUARANTEE)
# -------------------------
echo "🔹 Resetting app configs to ensure default (no-auth) install..."

for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
  if [[ "${INSTALL[$app]}" =~ ^[Yy]$ ]]; then
    rm -rf "$USER_HOME/$app"
    mkdir -p "$USER_HOME/$app"
    chown -R "$PUID:$PGID" "$USER_HOME/$app"
  fi
done

# -------------------------
# COMPOSE FILE
# -------------------------
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

add_service () {
  cat >> "$COMPOSE_FILE" <<EOF
  $1:
    image: $2
    container_name: $1
    environment:
      PUID: $PUID
      PGID: $PGID
      TZ: UTC
    volumes:
$3
    ports:
      - "$4"
    restart: unless-stopped

EOF
}

[[ "${INSTALL[sonarr]}" =~ ^[Yy]$ ]] && add_service sonarr ghcr.io/linuxserver/sonarr:latest "      - $MEDIA_ROOT:/media
      - $USER_HOME/sonarr:/config" "8989:8989"

[[ "${INSTALL[radarr]}" =~ ^[Yy]$ ]] && add_service radarr ghcr.io/linuxserver/radarr:latest "      - $MEDIA_ROOT:/media
      - $USER_HOME/radarr:/config" "7878:7878"

[[ "${INSTALL[bazarr]}" =~ ^[Yy]$ ]] && add_service bazarr ghcr.io/linuxserver/bazarr:latest "      - $MEDIA_ROOT:/media
      - $USER_HOME/bazarr:/config" "6767:6767"

[[ "${INSTALL[qbittorrent]}" =~ ^[Yy]$ ]] && add_service qbittorrent ghcr.io/linuxserver/qbittorrent:latest "      - $MEDIA_ROOT/downloads:/downloads
      - $USER_HOME/qbittorrent:/config" "8080:8080"

[[ "${INSTALL[prowlarr]}" =~ ^[Yy]$ ]] && add_service prowlarr ghcr.io/linuxserver/prowlarr:latest "      - $USER_HOME/prowlarr:/config" "9696:9696"

[[ "${INSTALL[jackett]}" =~ ^[Yy]$ ]] && add_service jackett ghcr.io/linuxserver/jackett:latest "      - $USER_HOME/jackett:/config" "9117:9117"

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

chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"

# -------------------------
# START
# -------------------------
$COMPOSE -f "$COMPOSE_FILE" up -d

# -------------------------
# DONE
# -------------------------
IP=$(hostname -I | awk '{print $1}')

echo
echo "✅ All apps deployed with DEFAULT (NO PASSWORD) settings"
echo "📁 Media path in apps: /media"
echo "🌐 Access via http://$IP:<port>"
echo "⚠️ Secure with firewall / VPN before public exposure"
