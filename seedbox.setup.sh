#!/usr/bin/env bash
set -e

echo "🚀 Seedbox setup started"

# Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "✅ Running as root"

# Detect internal IP
INTERNAL_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$INTERNAL_IP" ]]; then
    INTERNAL_IP="127.0.0.1"
fi
echo "ℹ️ Detected internal IP: $INTERNAL_IP"

# Detect external IP
EXTERNAL_IP=$(curl -s https://api.ipify.org || echo "UNKNOWN")
if [[ "$EXTERNAL_IP" == "UNKNOWN" ]]; then
    echo "⚠️ Could not detect external IP automatically."
else
    echo "ℹ️ Detected external IP: $EXTERNAL_IP"
fi

echo "⚠️ If you want to access these apps from outside your network, make sure ports are open on your router/firewall."

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

# Check for existing containers for a clean install
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

# Safe YAML service appender
add_service() {
    IMAGE_NAME="$2"
    SERVICE_NAME="$1"
    EXTRA="$3"

    cat >> "$COMPOSE_FILE" <<EOL
  $SERVICE_NAME:
    image: "$IMAGE_NAME"
    container_name: "$SERVICE_NAME"
    environment:
      - PUID=$(id -u $username)
      - PGID=$(id -g $username)
      - TZ=$TZ
EOL

    if [[ -n "$EXTRA" ]]; then
        while IFS= read -r line; do
            echo "    $line" >> "$COMPOSE_FILE"
        done <<< "$EXTRA"
    fi

    echo "    restart: unless-stopped" >> "$COMPOSE_FILE"
}

# Add services with correct ports
[[ "$install_sonarr" == "y" ]] && add_service "sonarr" "ghcr.io/linuxserver/sonarr:latest" "volumes:
  - $USER_HOME/sonarr:/config
  - $USER_HOME/media/tv:/tv
  - $USER_HOME/media/downloads:/downloads
ports:
  - 8989:8989"

[[ "$install_radarr" == "y" ]] && add_service "radarr" "ghcr.io/linuxserver/radarr:latest" "volumes:
  - $USER_HOME/radarr:/config
  - $USER_HOME/media/movies:/movies
  - $USER_HOME/media/downloads:/downloads
ports:
  - 7878:7878"

[[ "$install_qbittorrent" == "y" ]] && add_service "qbittorrent" "ghcr.io/linuxserver/qbittorrent:latest" "environment:
  - WEBUI_PORT=8080
volumes:
  - $USER_HOME/qbittorrent:/config
  - $USER_HOME/media/downloads:/downloads
ports:
  - 8080:8080
  - 6881:6881
  - 6881:6881/udp"

[[ "$install_bazarr" == "y" ]] && add_service "bazarr" "ghcr.io/linuxserver/bazarr:latest" "volumes:
  - $USER_HOME/bazarr:/config
  - $USER_HOME/media/tv:/tv
  - $USER_HOME/media/movies:/movies
ports:
  - 6767:6767"

[[ "$install_prowlarr" == "y" ]] && add_service "prowlarr" "ghcr.io/linuxserver/prowlarr:latest" "volumes:
  - $USER_HOME/prowlarr:/config
ports:
  - 9696:9696"

[[ "$install_listenarr" == "y" ]] && add_service "listenarr" "ghcr.io/therobbiedavis/listenarr:canary" "volumes:
  - $USER_HOME/listenarr:/app/config
  - $USER_HOME/media/music:/music
  - $USER_HOME/media/downloads:/downloads
ports:
  - 4545:4545"

[[ "$install_jackett" == "y" ]] && add_service "jackett" "ghcr.io/linuxserver/jackett:latest" "volumes:
  - $USER_HOME/jackett:/config
  - $USER_HOME/media/downloads:/downloads
ports:
  - 9117:9117"

echo "✅ Docker Compose file created at $COMPOSE_FILE"

# Start Docker containers
cd "$USER_HOME/docker"
docker-compose up -d

# ✅ Display summary of running containers with URLs
echo
echo "📊 Summary of running seedbox apps:"
for app in sonarr radarr qbittorrent bazarr prowlarr listenarr jackett; do
    if [[ "$(docker ps -q -f name=$app)" ]]; then
        # Pick the correct port for Web UI
        if [[ "$app" == "qbittorrent" ]]; then
            PORT=8080
        else
            PORT=$(docker ps -f name=$app --format '{{.Ports}}' | grep -o '[0-9]\{2,5\}->' | head -n1 | grep -o '[0-9]\{2,5\}')
        fi
        echo " - $app : UP"
        echo "     Internal URL: http://$INTERNAL_IP:$PORT"
        if [[ "$EXTERNAL_IP" != "UNKNOWN" ]]; then
            echo "     External URL: http://$EXTERNAL_IP:$PORT ⚠️ Make sure port is open"
        fi
    else
        echo " - $app : NOT RUNNING"
    fi
done

# Display temporary qBittorrent Web UI password
if [[ "$install_qbittorrent" == "y" ]]; then
    echo
    TEMP_PASS=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password is provided for this session: \K\w+')
    echo "🔑 qBittorrent temporary WebUI password: $TEMP_PASS"
    echo "ℹ️ Default username is: admin"
fi

echo "🚀 All selected apps are running via Docker"
