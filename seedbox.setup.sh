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

# Ask for password (hidden)
read -s -p "Enter password for $username: " password
echo
read -s -p "Retype password: " password2
echo

# Check if passwords match
if [[ "$password" != "$password2" ]]; then
    echo "❌ Passwords do not match."
    exit 1
fi

# Create the user
echo "Creating user '$username'..."
adduser --quiet --gecos "" --disabled-password "$username"

# Set the password
echo "$username:$password" | chpasswd

echo "✅ User '$username' created successfully"
