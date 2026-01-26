#!/usr/bin/env bash
set -e

echo "🚀 Setup script started"

# Check for root (important when using curl | bash)
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ This script must be run as root."
  echo "Use:"
  echo "curl -fsSL <url> | sudo bash"
  exit 1
fi

echo "✅ Running as root"