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

# Ask if user wants to create a new user
read -p "Do you want to create a new user? (y/n): " create_user

if [[ "$create_user" != "y" ]]; then
    echo "Skipping user creation."
    exit 0
fi

# Ask for username
read -p "Enter the new username: " username

# Basic validation: lowercase letters, numbers, dash or underscore
if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "❌ Invalid username. Use lowercase letters, numbers, '-' or '_' only."
    exit 1
fi

# Check if user already exists
if id "$username" &>/dev/null; then
    echo "❌ User '$username' already exists."
    exit 1
fi

# Create the user
echo "Creating user '$username'..."
adduser "$username"

echo "✅ User '$username' created successfully"
