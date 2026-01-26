#!/usr/bin/env bash
set -e

echo "🚀 Seedbox setup started"

# Root check
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ Please run as root."
  echo "Use:"
  echo "curl -fsSL https://raw.githubusercontent.com/teelge/SeedBoxAuto/main/seedbox.setup.sh | sudo bash"
  exit 1
fi

echo "✅ Running as root"

# Ask if user wants to create a new user
read -p "Do you want to create a new user? (y/n): " create_user

if [[ "$create_user" != "y" ]]; then
    echo "Skipping user creation."
    exit 0
fi

echo "User creation selected."
