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
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
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
      id "$SEEDUSER" >/dev/null 2>&1 || { echo "❌ User not found"; exit 1; }
    else
      read -r -p "Enter new username: " SEEDUSER
      adduser "$SEEDUSER"
    fi
  else
    read -r -p "Enter new username: " SEEDUSER
    adduser "$SEEDUSER"
  fi
}

prepare_paths() {
  USER_HOME=$(getent passwd "$SEEDUSER" | cut -d: -f6)
  [[ -z "${USER_HOME:-}" ]] && { echo "❌ Could not determine home directory for $SEEDUSER"; exit 1; }

  PUID=$(id -u "$SEEDUSER")
  PGID=$(id -g "$SEEDUSER")

  COMPOSE_DIR="$USER_HOME/docker"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  ENV_FILE="$COMPOSE_DIR/.env"

  mkdir -p "$COMPOSE_DIR" "$USER_HOME/media" "$USER_HOME/media/downloads"
  chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR" "$USER_HOME/media"

  # Create default .env if missing
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
PUID=$PUID
PGID=$PGID
TZ=UTC
USER_HOME=$USER_HOME
EOF
  fi
}

maybe_clean_install() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    if ask_yn "Existing Docker setup found. Do CLEAN install (deletes all app configs)?"; then
      echo "🔹 Removing old Docker setup..."
      detect_compose_cmd
      $DOCKER_COMPOSE -f "$COMPOSE_FILE" down || true
      rm -rf "$COMPOSE_DIR" "$USER_HOME"/{sonarr,radarr,qbittorrent,bazarr,prowlarr,listenarr,jackett,traefik}
      mkdir -p "$COMPOSE_DIR"
      chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"
      echo "✅ Clean install prepared"
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
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker 2>/dev/null || true
  fi

  detect_compose_cmd
  if [[ -z "$DOCKER_COMPOSE" ]]; then
    echo "🔹 Installing docker-compose..."
    if command -v apt >/dev/null 2>&1; then
      apt update -y && apt install -y docker-compose
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y docker-compose
    fi
    detect_compose_cmd
  fi

  [[ -z "$DOCKER_COMPOSE" ]] && { echo "❌ Could not install docker-compose"; exit 1; }

  usermod -aG docker "$SEEDUSER"
  echo "✅ Docker compose ready using: $DOCKER_COMPOSE"
}

select_apps() {
  declare -gA INSTALL=()
  APPS=(sonarr radarr qbittorrent bazarr prowlarr listenarr jackett)
  echo "🔹 Select apps to install:"
  for app in "${APPS[@]}"; do
    install="n"
    ask_yn "Install $app?" && install="y"
    INSTALL["$app"]="$install"
  done

  if ask_yn "Install Traefik reverse proxy (HTTPS/web dashboard)?"; then
    INSTALL["traefik"]="y"
  fi
}

generate_compose() {
  echo "🔹 Generating Docker Compose file..."
  cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

  add_service() {
    local name="$1" image="$2" volumes="$3" ports="$4" extra="$5"
    cat >> "$COMPOSE_FILE" <<EOF
  $name:
    image: $image
    container_name: $name
    env_file: $ENV_FILE
    volumes:
$volumes
    ports:
$ports
    restart: unless-stopped$extra
    networks:
      - seedbox

EOF
  }

  # Services
  [[ "${INSTALL[sonarr]:-n}" == "y" ]] && add_service sonarr ghcr.io/linuxserver/sonarr:latest \
"      - \${USER_HOME}/media/tv:/tv
      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/sonarr:/config" \
"      - 8989:8989" ""

  [[ "${INSTALL[radarr]:-n}" == "y" ]] && add_service radarr ghcr.io/linuxserver/radarr:latest \
"      - \${USER_HOME}/media/movies:/movies
      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/radarr:/config" \
"      - 7878:7878" ""

  [[ "${INSTALL[qbittorrent]:-n}" == "y" ]] && add_service qbittorrent ghcr.io/linuxserver/qbittorrent:latest \
"      - \${USER_HOME}/media/downloads:/downloads
      - \${USER_HOME}/qbittorrent:/config" \
"      - 8080:8080" ""

  [[ "${INSTALL[bazarr]:-n}" == "y" ]] && add_service bazarr ghcr.io/linuxserver/bazarr:latest \
"      - \${USER_HOME}/media:/media
      - \${USER_HOME}/bazarr:/config" \
"      - 6767:6767" ""

  [[ "${INSTALL[prowlarr]:-n}" == "y" ]] && add_service prowlarr ghcr.io/linuxserver/prowlarr:latest \
"      - \${USER_HOME}/prowlarr:/config" \
"      - 9696:9696" ""

  [[ "${INSTALL[listenarr]:-n}" == "y" ]] && add_service listenarr ghcr.io/therobbiedavis/listenarr:canary \
"      - \${USER_HOME}/listenarr:/app/config
      - \${USER_HOME}/media:/media
      - \${USER_HOME}/media/downloads:/downloads" \
"      - 4545:4545" ""

  [[ "${INSTALL[jackett]:-n}" == "y" ]] && add_service jackett ghcr.io/linuxserver/jackett:latest \
"      - \${USER_HOME}/jackett:/config" \
"      - 9117:9117" ""

  # Optional Traefik reverse proxy
  if [[ "${INSTALL[traefik]:-n}" == "y" ]]; then
    mkdir -p "$USER_HOME/traefik"
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

  echo "networks:
  seedbox:
    driver: bridge" >> "$COMPOSE_FILE"

  chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"
  echo "✅ Compose file created at $COMPOSE_FILE"
}

start_containers() {
  detect_compose_cmd
  echo "🔹 Starting containers..."
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d | tee "$COMPOSE_DIR/install.log"
}

print_summary() {
  declare -A PORTS=([sonarr]=8989 [radarr]=7878 [qbittorrent]=8080 [bazarr]=6767 [prowlarr]=9696 [listenarr]=4545 [jackett]=9117 [traefik]=8081)
  EXTERNAL_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "localhost")
  echo
  echo "📊 Summary of running seedbox apps:"
  for c in "${!PORTS[@]}"; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    echo " - $c : http://$EXTERNAL_IP:${PORTS[$c]}"
  done
}

main "$@"
