#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

main() {
  echo "🚀 Seedbox setup started"

  check_root
  select_user
  prepare_paths
  maybe_clean_install
  install_docker_stack
  select_apps
  generate_compose
  start_containers
  print_summary

  echo
  echo "✅ All selected seedbox apps deployed successfully!"
  echo "ℹ️ If you run Docker as $SEEDUSER, log out and back in so group changes take effect."
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "❌ Please run via: sudo $0"
    exit 1
  fi
  echo "✅ Running as root"
}

ask_yn() {
  local prompt="$1" reply
  while true; do
    read -r -p "$prompt (y/n): " reply
    case "$reply" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

select_user() {
  local users
  users=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd || true)

  if [[ -n "$users" ]]; then
    echo "Existing non-root users detected:"
    echo "$users"
    if ask_yn "Do you want to use an existing user?"; then
      read -r -p "Enter username: " SEEDUSER
      if ! id "$SEEDUSER" >/dev/null 2>&1; then
        echo "❌ User not found"
        exit 1
      fi
    else
      read -r -p "Enter new username: " SEEDUSER
      adduser "$SEEDUSER"
    fi
  else
    echo "No existing non-root users found."
    read -r -p "Enter new username: " SEEDUSER
    adduser "$SEEDUSER"
  fi
}

prepare_paths() {
  USER_HOME=$(getent passwd "$SEEDUSER" | cut -d: -f6)
  if [[ -z "${USER_HOME:-}" ]]; then
    echo "❌ Could not determine home directory for $SEEDUSER"
    exit 1
  fi

  PUID=$(id -u "$SEEDUSER")
  PGID=$(id -g "$SEEDUSER")

  COMPOSE_DIR="$USER_HOME/docker"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  ENV_FILE="$COMPOSE_DIR/.env"

  mkdir -p "$COMPOSE_DIR"
  chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"

  mkdir -p "$USER_HOME/media" "$USER_HOME/media/downloads"
  chown -R "$SEEDUSER:$SEEDUSER" "$USER_HOME/media"

  # Always (re)create a sane .env for this stack
  cat > "$ENV_FILE" <<EOF
PUID=$PUID
PGID=$PGID
TZ=UTC
USER_HOME=$USER_HOME
EOF
  chown "$SEEDUSER:$SEEDUSER" "$ENV_FILE"
}

maybe_clean_install() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    if ask_yn "Existing Docker setup found. Do CLEAN install (this will DELETE all app settings and configs)?"; then
      echo "🔹 Removing old Docker setup and configs..."

      detect_compose_cmd
      if [[ -n "$DOCKER_COMPOSE" ]]; then
        $DOCKER_COMPOSE -f "$COMPOSE_FILE" down || true
      fi

      rm -rf "$COMPOSE_DIR"

      rm -rf \
        "$USER_HOME/sonarr" \
        "$USER_HOME/radarr" \
        "$USER_HOME/qbittorrent" \
        "$USER_HOME/bazarr" \
        "$USER_HOME/prowlarr" \
        "$USER_HOME/listenarr" \
        "$USER_HOME/jackett" \
        "$USER_HOME/traefik"

      mkdir -p "$COMPOSE_DIR"
      chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"

      echo "✅ Clean install prepared (all previous app settings removed)"
    fi
  fi
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
  else
    DOCKER_COMPOSE=""
  fi
}

install_docker_stack() {
  echo "🔹 Checking Docker..."
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker 2>/dev/null || true
  fi
  echo "✅ Docker installed"

  echo "🔹 Checking docker compose..."
  detect_compose_cmd
  if [[ -z "$DOCKER_COMPOSE" ]]; then
    if command -v apt >/dev/null 2>&1; then
      apt update -y
      apt install -y docker-compose || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y docker-compose || true
    fi
    detect_compose_cmd
    if [[ -z "$DOCKER_COMPOSE" ]]; then
      echo "❌ Could not install docker-compose or docker compose"
      exit 1
    fi
  fi
  echo "✅ docker compose ready: $DOCKER_COMPOSE"

  usermod -aG docker "$SEEDUSER"

  echo "🔹 Waiting for Docker daemon..."
  until docker info >/dev/null 2>&1; do
    sleep 2
  done
  echo "✅ Docker daemon running"
}

select_apps() {
  declare -gA INSTALL=()
  APPS=(sonarr radarr qbittorrent bazarr prowlarr listenarr jackett)

  echo "🔹 Select apps to install:"
  for app in "${APPS[@]}"; do
    if ask_yn "Install $app?"; then
      INSTALL["$app"]="y"
    else
      INSTALL["$app"]="n"
    fi
  done

  if ask_yn "Install Traefik reverse proxy (HTTPS/web dashboard)?"; then
    INSTALL["traefik"]="y"
  else
    INSTALL["traefik"]="n"
  fi
}

generate_compose() {
  echo "🔹 Generating Docker Compose file..."

  cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
EOF

  add_service() {
    local name="$1"
    local image="$2"
    local volumes="$3"
    local ports="$4"
    local extra="$5"

    cat >> "$COMPOSE_FILE" <<EOF
  $name:
    image: $image
    container_name: $name
    env_file:
      - .env
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
$volumes
    ports:
$ports
    restart: unless-stopped$extra
    networks:
      - seedbox

EOF
  }

  # Sonarr
  if [[ "${INSTALL[sonarr]:-n}" == "y" ]]; then
    add_service \
      "sonarr" \
      "ghcr.io/linuxserver/sonarr:latest" \
"      - \${USER_HOME}/media/tv:/tv
      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/sonarr:/config" \
"      - 8989:8989" \
""
  fi

  # Radarr
  if [[ "${INSTALL[radarr]:-n}" == "y" ]]; then
    add_service \
      "radarr" \
      "ghcr.io/linuxserver/radarr:latest" \
"      - \${USER_HOME}/media/movies:/movies
      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/radarr:/config" \
"      - 7878:7878" \
""
  fi

  # qBittorrent
  if [[ "${INSTALL[qbittorrent]:-n}" == "y" ]]; then
    add_service \
      "qbittorrent" \
      "ghcr.io/linuxserver/qbittorrent:latest" \
"      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/qbittorrent:/config" \
"      - 8080:8080" \
""
  fi

  # Bazarr
  if [[ "${INSTALL[bazarr]:-n}" == "y" ]]; then
    add_service \
      "bazarr" \
      "ghcr.io/linuxserver/bazarr:latest" \
"      - \${USER_HOME}/media:/media
      - \${USER_HOME}/bazarr:/config" \
"      - 6767:6767" \
""
  fi

  # Prowlarr
  if [[ "${INSTALL[prowlarr]:-n}" == "y" ]]; then
    add_service \
      "prowlarr" \
      "ghcr.io/linuxserver/prowlarr:latest" \
"      - \${USER_HOME}/prowlarr:/config" \
"      - 9696:9696" \
""
  fi

  # Listenarr
  if [[ "${INSTALL[listenarr]:-n}" == "y" ]]; then
    add_service \
      "listenarr" \
      "ghcr.io/therobbiedavis/listenarr:canary" \
"      - \${USER_HOME}/listenarr:/app/config
      - \${USER_HOME}/media:/media
      - \${USER_HOME}/media/downloads:/downloads" \
"      - 4545:4545" \
""
  fi

  # Jackett
  if [[ "${INSTALL[jackett]:-n}" == "y" ]]; then
    add_service \
      "jackett" \
      "ghcr.io/linuxserver/jackett:latest" \
"      - \${USER_HOME}/jackett:/config" \
"      - 9117:9117" \
""
  fi

  # Optional Traefik
  if [[ "${INSTALL[traefik]:-n}" == "y" ]]; then
    mkdir -p "$USER_HOME/traefik"
    chown -R "$SEEDUSER:$SEEDUSER" "$USER_HOME/traefik"
    cat >> "$COMPOSE_FILE" <<EOF
  traefik:
    image: traefik:v3.1
    container_name: traefik
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
    ports:
      - "80:80"
      - "8081:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - \${USER_HOME}/traefik:/etc/traefik
    restart: unless-stopped
    networks:
      - seedbox

EOF
  fi

  cat >> "$COMPOSE_FILE" <<EOF
networks:
  seedbox:
    driver: bridge
EOF

  chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"
  echo "✅ Docker Compose file created at $COMPOSE_FILE"
}

start_containers() {
  echo "🔹 Starting containers..."
  detect_compose_cmd
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
  sleep 5
}

detect_ips() {
  INTERNAL_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
  if [[ -z "${INTERNAL_IP:-}" ]]; then
    INTERNAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "${INTERNAL_IP:-}" ]]; then
    INTERNAL_IP="localhost"
  fi

  EXTERNAL_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "UNKNOWN")
}

print_summary() {
  detect_ips

  declare -A PORTS=(
    [sonarr]=8989
    [radarr]=7878
    [qbittorrent]=8080
    [bazarr]=6767
    [prowlarr]=9696
    [listenarr]=4545
    [jackett]=9117
    [traefik]=8081
  )

  echo
  echo "📊 Summary of running seedbox apps:"

  for c in "${!PORTS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
      local port="${PORTS[$c]}"
      echo " - $c : UP"
      echo "     Internal URL: http://$INTERNAL_IP:$port"
      if [[ "$EXTERNAL_IP" != "UNKNOWN" ]]; then
        echo "     External URL: http://$EXTERNAL_IP:$port ⚠️ Make sure port is open"
      fi
    fi
  done
}

main "$@"
