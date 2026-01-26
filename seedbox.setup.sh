#!/bin/bash
set -e

echo "🚀 Seedbox setup started"

# -------------------------
# ROOT CHECK
# -------------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi
echo "✅ Running as root"

# -------------------------
# USER SELECTION
# -------------------------
USERS=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)

if [ -n "$USERS" ]; then
  echo "Existing non-root users detected:"
  echo "$USERS"
  read -p "Do you want to use an existing user? (y/n): " USE_EXISTING
fi

if [[ "$USE_EXISTING" == "y" ]]; then
  read -p "Enter the username to use: " SEEDUSER
  id "$SEEDUSER" >/dev/null 2>&1 || { echo "❌ User not found"; exit 1; }
else
  read -p "Enter new username: " SEEDUSER
  adduser "$SEEDUSER"
fi

USER_HOME=$(eval echo "~$SEEDUSER")
PUID=$(id -u "$SEEDUSER")
PGID=$(id -g "$SEEDUSER")

# -------------------------
# CLEAN INSTALL CHECK
# -------------------------
COMPOSE_DIR="$USER_HOME/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

if [ -f "$COMPOSE_FILE" ]; then
  read -p "Existing Docker setup found. Do CLEAN install? (y/n): " CLEAN
  if [[ "$CLEAN" == "y" ]]; then
    echo "🔹 Removing old Docker setup..."
    docker-compose -f "$COMPOSE_FILE" down || true
    rm -rf "$COMPOSE_DIR"
    echo "✅ Clean install prepared"
  fi
fi

# -------------------------
# DOCKER INSTALL
# -------------------------
echo "🔹 Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
echo "✅ Docker installed"

echo "🔹 Installing docker-compose..."
if ! command -v docker-compose >/dev/null 2>&1; then
  apt update -y
  apt install -y docker-compose
fi
echo "✅ docker-compose ready"

usermod -aG docker "$SEEDUSER"

# -------------------------
# WAIT FOR DOCKER
# -------------------------
echo "🔹 Waiting for Docker daemon..."
until docker info >/dev/null 2>&1; do
  sleep 2
done
echo "✅ Docker daemon running"

# -------------------------
# APP SELECTION
# -------------------------
declare -A INSTALL

for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
  read -p "Install $app? (y/n): " INSTALL[$app]
done

mkdir -p "$COMPOSE_DIR"
chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"

# -------------------------
# GENERATE COMPOSE FILE
# -------------------------
echo "🔹 Generating Docker Compose file..."

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
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
      - $USER_HOME/$1:/config
$3
    ports:
      - $4
    restart: unless-stopped

EOF
}

# -------------------------
# ADD SERVICES
# -------------------------
[ "${INSTALL[sonarr]}" = "y" ] && add_service sonarr ghcr.io/linuxserver/sonarr:latest "      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads" "8989:8989"

[ "${INSTALL[radarr]}" = "y" ] && add_service radarr ghcr.io/linuxserver/radarr:latest "      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads" "7878:7878"

# Fix: remove duplicate /config mount
[ "${INSTALL[qbittorrent]}" = "y" ] && add_service qbittorrent ghcr.io/linuxserver/qbittorrent:latest "      - $USER_HOME/media/downloads:/downloads" "8080:8080"

[ "${INSTALL[bazarr]}" = "y" ] && add_service bazarr ghcr.io/linuxserver/bazarr:latest "      - $USER_HOME/media:/media" "6767:6767"

[ "${INSTALL[prowlarr]}" = "y" ] && add_service prowlarr ghcr.io/linuxserver/prowlarr:latest "" "9696:9696"

if [ "${INSTALL[listenarr]}" = "y" ]; then
cat >> "$COMPOSE_FILE" <<EOF
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: "$PUID:$PGID"
    volumes:
      - $USER_HOME/listenarr:/app/config
    ports:
      - 4545:4545
    restart: unless-stopped

EOF
fi

[ "${INSTALL[jackett]}" = "y" ] && add_service jackett ghcr.io/linuxserver/jackett:latest "" "9117:9117"

chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"
echo "✅ Docker Compose file created at $COMPOSE_FILE"

# -------------------------
# START CONTAINERS
# -------------------------
echo "🔹 Starting containers..."
docker-compose -f "$COMPOSE_FILE" up -d
sleep 10  # Give extra time for slower machines

# -------------------------
# IP DETECTION
# -------------------------
INTERNAL_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -s https://api.ipify.org || echo "UNKNOWN")

# -------------------------
# QBITTORRENT TEMP PASSWORD
# -------------------------
if [ "${INSTALL[qbittorrent]}" = "y" ]; then
  TEMP_PASS=$(docker logs qbittorrent 2>/dev/null | grep "temporary password" | awk -F': ' '{print $2}' | tail -n1)
fi

# -------------------------
# STATUS + URL OUTPUT
# -------------------------
echo
echo "📊 Summary of running seedbox apps:"

for c in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
  if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
    PORT=$(docker port $c | head -n1 | awk -F: '{print $2}')
    echo " - $c : UP"
    echo "     Internal URL: http://$INTERNAL_IP:$PORT"
    if [ "$EXTERNAL_IP" != "UNKNOWN" ]; then
      echo "     External URL: http://$EXTERNAL_IP:$PORT ⚠️ Make sure port is open"
    fi
  fi
done

if [ -n "$TEMP_PASS" ]; then
  echo
  echo "⚠️ qbittorrent WebUI temporary password: $TEMP_PASS (username: admin)"
  echo "   You should set a new password in WebUI preferences."
fi
