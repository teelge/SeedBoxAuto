#!/usr/bin/env bash
set -e

echo "🚀 Seedbox setup started"

# Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "✅ Running as root"

# List existing non-root users
existing_users=$(awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd)

USER_HOME=""
username=""

if [[ -n "$existing_users" ]]; then
    echo "Existing non-root users detected:"
    echo "$existing_users"
    read -p "Do you want to use an existing user? (y/n): " use_existing
    if [[ "$use_existing" == "y" ]]; then
        read -p "Enter the username to use: " username
        if ! id "$username" &>/dev/null; then
            echo "❌ User '$username' does not exist."
            exit 1
        fi
        USER_HOME=$(eval echo "~$username")
    fi
fi

# If no existing user selected, create a new one
if [[ -z "$username" ]]; then
    read -p "Enter the new username: " username
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "❌ Invalid username."
        exit 1
    fi
    if id "$username" &>/dev/null; then
        echo "❌ User '$username' already exists."
        exit 1
    fi
    read -s -p "Enter password for $username: " password
    echo
    read -s -p "Retype password: " password2
    echo
    if [[ "$password" != "$password2" ]]; then
        echo "❌ Passwords do not match."
        exit 1
    fi
    echo "Creating user '$username'..."
    adduser --quiet --gecos "" --disabled-password "$username"
    echo "$username:$password" | chpasswd
    usermod -aG sudo "$username"
    echo "✅ User '$username' created and added to sudo"
    USER_HOME=$(eval echo "~$username")
fi

# Ensure media and docker directories exist
mkdir -p "$USER_HOME/docker" \
         "$USER_HOME/media/tv" \
         "$USER_HOME/media/movies" \
         "$USER_HOME/media/music" \
         "$USER_HOME/media/downloads"

COMPOSE_FILE="$USER_HOME/docker/docker-compose.yml"

# Ask if user wants a clean install
existing_containers=$(docker ps -a --format '{{.Names}}' | grep -E "sonarr|radarr|qbittorrent|bazarr|prowlarr|listenarr|jackett" || true)
if [[ -n "$existing_containers" ]]; then
    echo "⚠️ Existing containers detected: $existing_containers"
    read -p "Do you want to remove existing containers for a clean install? (y/n): " clean_install
    if [[ "$clean_install" == "y" ]]; then
        echo "Stopping and removing containers..."
        docker rm -f $existing_containers || true
        echo "✅ Existing containers removed"
    fi
fi

# Ask which apps to install
echo "Which apps do you want to install? (y/n)"
read -p "Sonarr: " install_sonarr
read -p "Radarr: " install_radarr
read -p "qBittorrent: " install_qbittorrent
read -p "Bazarr: " install_bazarr
read -p "Prowlarr: " install_prowlarr
read -p "Listenarr: " install_listenarr
read -p "Jackett: " install_jackett

# Install Docker if not present
if ! command -v docker &>/dev/null; then
    echo "⚙️ Installing Docker..."
    apt update && apt install -y docker.io docker-compose
fi

# Create docker-compose.yml
echo "version: '3.8'" > "$COMPOSE_FILE"
echo "services:" >> "$COMPOSE_FILE"
TZ="America/New_York"

# Append service to compose file safely
add_service() {
    IMAGE_NAME="$2"
    cat >> "$COMPOSE_FILE" <<EOL
  $1:
    image: "$IMAGE_NAME"
    container_name: "$1"
    environment:
      - PUID=$(id -u $username)
      - PGID=$(id -g $username)
      - TZ=$TZ
EOL

    if [[ -n "$3" ]]; then
        echo "$3" | sed 's/^/    /' >> "$COMPOSE_FILE"
    fi

    echo "    restart: unless-stopped" >> "$COMPOSE_FILE"
}

# Sonarr
[[ "$install_sonarr" == "y" ]] && add_service "sonarr" "ghcr.io/linuxserver/sonarr:latest" "    volumes:
      - $USER_HOME/sonarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8989:8989"

# Radarr
[[ "$install_radarr" == "y" ]] && add_service "radarr" "ghcr.io/linuxserver/radarr:latest" "    volumes:
      - $USER_HOME/radarr:/config
      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 7878:7878"

# qBittorrent
[[ "$install_qbittorrent" == "y" ]] && add_service "qbittorrent" "ghcr.io/linuxserver/qbittorrent:latest" "    environment:
      - WEBUI_PORT=8080
    volumes:
      - $USER_HOME/qbittorrent:/config
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp"

# Bazarr
[[ "$install_bazarr" == "y" ]] && add_service "bazarr" "ghcr.io/linuxserver/bazarr:latest" "    volumes:
      - $USER_HOME/bazarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/movies:/movies
    ports:
      - 6767:6767"

# Prowlarr
[[ "$install_prowlarr" == "y" ]] && add_service "prowlarr" "ghcr.io/linuxserver/prowlarr:latest" "    volumes:
      - $USER_HOME/prowlarr:/config
    ports:
      - 9696:9696"

# Listenarr
[[ "$install_listenarr" == "y" ]] && add_service "listenarr" "ghcr.io/therobbiedavis/listenarr:canary" "    volumes:
      - $USER_HOME/listenarr:/app/config
      - $USER_HOME/media/music:/music
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 4545:4545"

# Jackett
[[ "$install_jackett" == "y" ]] && add_service "jackett" "ghcr.io/linuxserver/jackett:latest" "    volumes:
      - $USER_HOME/jackett:/config
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 9117:9117"

echo "✅ Docker Compose file created at $COMPOSE_FILE"

# Start Docker containers
cd "$USER_HOME/docker"
docker-compose up -d

echo "🚀 Selected apps are running via Docker"
