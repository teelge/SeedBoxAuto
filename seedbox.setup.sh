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
      read -r -p "Enter the username to use: " SEEDUSER
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

  mkdir -p "$COMPOSE_DIR"
  chown -R "$SEEDUSER:$SEEDUSER" "$COMPOSE_DIR"

  mkdir -p "$USER_HOME/media" "$USER_HOME/media/downloads"
  chown -R "$SEEDUSER:$SEEDUSER" "$USER_HOME/media"
}

maybe_clean_install() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    if ask_yn "Existing Docker setup found. Do CLEAN install (this will DELETE all app settings and configs)?"; then
      echo "🔹 Removing old Docker setup and configs..."

      if command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$COMPOSE_FILE" down || true
      elif docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" down || true
      fi

      rm -rf "$COMPOSE_DIR"

      rm -rf \
        "$USER_HOME/sonarr" \
        "$USER_HOME/radarr" \
        "$USER_HOME/qbittorrent" \
        "$USER_HOME/bazarr" \
        "$USER_HOME/prowlarr" \
        "$USER_HOME/listenarr" \
        "$USER_HOME/jackett"

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
    apt update -y
    apt install -y docker-compose || true
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
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
$volumes
    ports:
$ports
    restart: unless-stopped$extra

EOF
  }

  if [[ "${INSTALL[qbittorrent]:-n}" == "y" ]]; then
    add_service \
      "qbittorrent" \
      "ghcr.io/linuxserver/qbittorrent:latest" \
"      - $USER_HOME/media/downloads:/downloads
      - $USER_HOME/qbittorrent:/config" \
"      - 8080:8080" \
""
  fi

  chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"
  echo "✅ Docker Compose file created at $COMPOSE_FILE"
}

start_containers() {
  echo "🔹 Starting containers..."
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
  sleep 5
}

detect_ips() {
  INTERNAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
  EXTERNAL_IP=$(curl -s --max-time 3 https://api.ipify.org || echo "UNKNOWN")
}

print_qbittorrent_credentials() {
  if ! docker ps --format '{{.Names}}' | grep -qx "qbittorrent"; then
    return
  fi

  local logs username password

  logs=$(docker logs qbittorrent 2>/dev/null || true)

  username=$(echo "$logs" | awk -F': ' '/administrator username is:/ {print $2}' | tail -n1)
  password=$(echo "$logs" | awk -F': ' '/temporary password is provided/ {print $NF}' | tail -n1)

  if [[ -n "${username:-}" && -n "${password:-}" ]]; then
    echo
    echo "🔐 qBittorrent WebUI credentials (temporary):"
    echo "     Username: $username"
    echo "     Password: $password"
    echo "     ⚠️ Change this password immediately in qBittorrent settings"
  fi
}

print_summary() {
  detect_ips

  echo
  echo "📊 Summary of running seedbox apps:"

  if docker ps --format '{{.Names}}' | grep -qx "qbittorrent"; then
    echo " - qbittorrent : UP"
    echo "     Internal URL: http://$INTERNAL_IP:8080"
    [[ "$EXTERNAL_IP" != "UNKNOWN" ]] && echo "     External URL: http://$EXTERNAL_IP:8080 ⚠️ Make sure port is open"
  fi

  print_qbittorrent_credentials
}

main "$@"
