#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

print_qbittorrent_credentials() {
  if ! docker ps --format '{{.Names}}' | grep -qx "qbittorrent"; then
    return
  fi

  local logs username password i

  for i in {1..30}; do
    logs=$(docker logs qbittorrent 2>/dev/null || true)

    username=$(echo "$logs" | awk -F': ' '/administrator username is:/ {print $2}' | tail -n1)
    password=$(echo "$logs" | awk -F': ' '/temporary password is provided/ {print $NF}' | tail -n1)

    [[ -n "$username" && -n "$password" ]] && break
    sleep 2
  done

  if [[ -n "$username" && -n "$password" ]]; then
    echo
    echo "🔐 qBittorrent WebUI credentials (temporary):"
    echo "     Username: $username"
    echo "     Password: $password"
    echo "     ⚠️ Change this password immediately in qBittorrent settings"
  fi
}

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
  [[ "$EUID" -eq 0 ]] || { echo "❌ Please run via: sudo $0"; exit 1; }
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
    echo "$users"
    ask_yn "Use existing user?" && read -r -p "Username: " SEEDUSER || { read -r -p "New username: " SEEDUSER; adduser "$SEEDUSER"; }
  else
    read -r -p "New username: " SEEDUSER
    adduser "$SEEDUSER"
  fi

  id "$SEEDUSER" >/dev/null 2>&1 || { echo "❌ User not found"; exit 1; }
}

prepare_paths() {
  USER_HOME=$(getent passwd "$SEEDUSER" | cut -d: -f6)
  PUID=$(id -u "$SEEDUSER")
  PGID=$(id -g "$SEEDUSER")

  COMPOSE_DIR="$USER_HOME/docker"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

  mkdir -p "$COMPOSE_DIR" "$USER_HOME/media/downloads"
  chown -R "$SEEDUSER:$SEEDUSER" "$USER_HOME"
}

maybe_clean_install() {
  [[ -f "$COMPOSE_FILE" ]] || return
  ask_yn "CLEAN install (deletes all configs)?" || return

  docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  rm -rf "$COMPOSE_DIR" "$USER_HOME"/{sonarr,radarr,qbittorrent,bazarr,prowlarr,listenarr,jackett}
  mkdir -p "$COMPOSE_DIR"
}

detect_compose_cmd() {
  docker compose version >/dev/null 2>&1 && DOCKER_COMPOSE="docker compose" ||
  command -v docker-compose >/dev/null 2>&1 && DOCKER_COMPOSE="docker-compose" || DOCKER_COMPOSE=""
}

install_docker_stack() {
  command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  detect_compose_cmd || apt install -y docker-compose
  usermod -aG docker "$SEEDUSER"

  until docker info >/dev/null 2>&1; do sleep 2; done
}

select_apps() {
  declare -gA INSTALL=()
  for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
    ask_yn "Install $app?" && INSTALL[$app]=y || INSTALL[$app]=n
  done
}

generate_compose() {
  cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
EOF

  add_lsio() {
    cat >> "$COMPOSE_FILE" <<EOF
  $1:
    image: $2
    container_name: $1
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=UTC
    volumes:
$3
    ports:
$4
    restart: unless-stopped

EOF
  }

  [[ ${INSTALL[qbittorrent]} == y ]] && add_lsio qbittorrent ghcr.io/linuxserver/qbittorrent:latest \
"      - $USER_HOME/media/downloads:/downloads
      - $USER_HOME/qbittorrent:/config" \
"      - 8080:8080"

  [[ ${INSTALL[sonarr]} == y ]] && add_lsio sonarr ghcr.io/linuxserver/sonarr:latest \
"      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads
      - $USER_HOME/sonarr:/config" \
"      - 8989:8989"

  [[ ${INSTALL[radarr]} == y ]] && add_lsio radarr ghcr.io/linuxserver/radarr:latest \
"      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads
      - $USER_HOME/radarr:/config" \
"      - 7878:7878"

  [[ ${INSTALL[bazarr]} == y ]] && add_lsio bazarr ghcr.io/linuxserver/bazarr:latest \
"      - $USER_HOME/media:/media
      - $USER_HOME/bazarr:/config" \
"      - 6767:6767"

  [[ ${INSTALL[prowlarr]} == y ]] && add_lsio prowlarr ghcr.io/linuxserver/prowlarr:latest \
"      - $USER_HOME/prowlarr:/config" \
"      - 9696:9696"

  [[ ${INSTALL[jackett]} == y ]] && add_lsio jackett ghcr.io/linuxserver/jackett:latest \
"      - $USER_HOME/jackett:/config" \
"      - 9117:9117"

  if [[ ${INSTALL[listenarr]} == y ]]; then
cat >> "$COMPOSE_FILE" <<EOF
  listenarr:
    image: ghcr.io/therobbiedavis/listenarr:canary
    container_name: listenarr
    user: "$PUID:$PGID"
    environment:
      - LISTENARR_PUBLIC_URL=http://localhost:4545
    volumes:
      - listenarr_data:/app/config
    ports:
      - 4545:4545
    restart: unless-stopped

volumes:
  listenarr_data:
EOF
  fi

  chown "$SEEDUSER:$SEEDUSER" "$COMPOSE_FILE"
}

start_containers() {
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
  sleep 5
}

detect_ips() {
  INTERNAL_IP=$(hostname -I | awk '{print $1}')
  EXTERNAL_IP=$(curl -s https://api.ipify.org || echo UNKNOWN)
}

print_summary() {
  detect_ips
  echo "📊 Summary of running seedbox apps:"

  for c in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    port=$(docker port "$c" | awk -F: '{print $2}')
    echo " - $c : UP"
    echo "     http://$INTERNAL_IP:$port"
  done

  print_qbittorrent_credentials
}

main "$@"
