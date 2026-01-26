#!/usr/bin/env bash
set -e

echo "🚀 Seedbox setup started"

# Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ Please run as root."
    echo "Use:"
    echo "sudo bash -c \"\$(wget -qO- URL)\""
    exit 1
fi

echo "✅ Running as root"

# Ask for new user info
read -p "Enter the new username: " username

# Basic validation
if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "❌ Invalid username."
    exit 1
fi

# Check if user exists
if id "$username" &>/dev/null; then
    echo "❌ User '$username' already exists."
    exit 1
fi

# Ask for password
read -s -p "Enter password for $username: " password
echo
read -s -p "Retype password: " password2
echo
if [[ "$password" != "$password2" ]]; then
    echo "❌ Passwords do not match."
    exit 1
fi

# Create user and add to sudo
echo "Creating user '$username'..."
adduser --quiet --gecos "" --disabled-password "$username"
echo "$username:$password" | chpasswd
usermod -aG sudo "$username"
echo "✅ User '$username' created and added to sudo"

# Get user's home directory
USER_HOME=$(eval echo "~$username")
mkdir -p "$USER_HOME/docker"
COMPOSE_FILE="$USER_HOME/docker/docker-compose.yml"

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

# Functions to append each app
add_service() {
    cat >> "$COMPOSE_FILE" <<EOL
  $1:
    image: $2:latest
    container_name: $1
    environment:
      - PUID=$(id -u $username)
      - PGID=$(id -g $username)
      - TZ=$TZ
$3
    restart: unless-stopped
EOL
}

# Sonarr
if [[ "$install_sonarr" == "y" ]]; then
add_service "sonarr" "ghcr.io/linuxserver/sonarr" "    volumes:
      - $USER_HOME/sonarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8989:8989"
fi

# Radarr
if [[ "$install_radarr" == "y" ]]; then
add_service "radarr" "ghcr.io/linuxserver/radarr" "    volumes:
      - $USER_HOME/radarr:/config
      - $USER_HOME/media/movies:/movies
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 7878:7878"
fi

# qBittorrent
if [[ "$install_qbittorrent" == "y" ]]; then
add_service "qbittorrent" "ghcr.io/linuxserver/qbittorrent" "    environment:
      - WEBUI_PORT=8080
    volumes:
      - $USER_HOME/qbittorrent:/config
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp"
fi

# Bazarr
if [[ "$install_bazarr" == "y" ]]; then
add_service "bazarr" "ghcr.io/linuxserver/bazarr" "    volumes:
      - $USER_HOME/bazarr:/config
      - $USER_HOME/media/tv:/tv
      - $USER_HOME/media/movies:/movies
    ports:
      - 6767:6767"
fi

# Prowlarr
if [[ "$install_prowlarr" == "y" ]]; then
add_service "prowlarr" "ghcr.io/linuxserver/prowlarr" "    volumes:
      - $USER_HOME/prowlarr:/config
    ports:
      - 9696:9696"
fi

# Listenarr (updated port 4545)
if [[ "$install_listenarr" == "y" ]]; then
add_service "listenarr" "ghcr.io/linuxserver/listenarr" "    volumes:
      - $USER_HOME/listenarr:/config
      - $USER_HOME/media/music:/music
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 4545:4545"
fi

# Jackett
if [[ "$install_jackett" == "y" ]]; then
add_service "jackett" "ghcr.io/linuxserver/jackett" "    volumes:
      - $USER_HOME/jackett:/config
      - $USER_HOME/media/downloads:/downloads
    ports:
      - 9117:9117"
fi

echo "✅ Docker Compose file created at $COMPOSE_FILE"

# Start Docker containers
cd "$USER_HOME/docker"
docker-compose up -d

echo "🚀 Selected apps are running via Docker"
