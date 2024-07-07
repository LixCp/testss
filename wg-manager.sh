#!/bin/bash

CONFIG_DIR="/etc/wireguard"
USER_DB="$CONFIG_DIR/users.db"
SCRIPT_NAME="wg-manager"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$CONFIG_DIR/wg-manager.log"
}

# Function to install the script
install_script() {
    local script_path="/bin/$SCRIPT_NAME"
    cp "$0" "$script_path"
    chmod +x "$script_path"
    log_message "Script installed as $script_path"
    echo "Script installed as $script_path"
    echo "You can now run it from anywhere using: sudo $SCRIPT_NAME"
    exit 0
}

# Function to install WireGuard and set up initial configuration
install_wireguard() {
    apt update && apt install -y wireguard iptables || { echo "Failed to install WireGuard or iptables"; log_message "Failed to install WireGuard or iptables"; exit 1; }

    # Generate server keys
    umask 077
    wg genkey | tee $CONFIG_DIR/server_private.key | wg pubkey > $CONFIG_DIR/server_public.key || { echo "Failed to generate server keys"; log_message "Failed to generate server keys"; exit 1; }

    # Set up WireGuard configuration
    cat << EOF > $CONFIG_DIR/wg0.conf
[Interface]
PrivateKey = $(cat $CONFIG_DIR/server_private.key)
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = true

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

    # Enable IP forwarding
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p || { echo "Failed to enable IP forwarding"; log_message "Failed to enable IP forwarding"; exit 1; }

    # Start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0 || { echo "Failed to start WireGuard"; log_message "Failed to start WireGuard"; exit 1; }

    log_message "WireGuard installed and configured."
    echo "WireGuard installed and configured."
}

# Function to add a new user
add_user() {
    read -p "Enter username: " username
    read -p "Enter data limit in GB (leave blank for unlimited): " data_limit
    read -p "Enter monthly traffic limit in GB (leave blank for unlimited): " traffic_limit

    if [[ -z "$username" ]]; then
        echo "Username cannot be empty."
        return
    fi

    # Generate user keys
    umask 077
    wg genkey | tee $CONFIG_DIR/${username}_private.key | wg pubkey > $CONFIG_DIR/${username}_public.key || { echo "Failed to generate user keys"; log_message "Failed to generate user keys for $username"; return; }

    # Calculate next available IP
    next_ip=$(($(grep -c "\[Peer\]" $CONFIG_DIR/wg0.conf) + 2))

    # Add user to WireGuard config
    cat << EOF >> $CONFIG_DIR/wg0.conf

[Peer]
PublicKey = $(cat $CONFIG_DIR/${username}_public.key)
AllowedIPs = 10.0.0.${next_ip}/32
EOF

    # Create user config file
    cat << EOF > $CONFIG_DIR/${username}.conf
[Interface]
PrivateKey = $(cat $CONFIG_DIR/${username}_private.key)
Address = 10.0.0.${next_ip}/32
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat $CONFIG_DIR/server_public.key)
Endpoint = $(curl -s ifconfig.me):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Add user to database
    echo "$username,$next_ip,$data_limit,$traffic_limit" >> $USER_DB

    log_message "User $username added successfully."
    echo "User $username added successfully."
    wg-quick down wg0 && wg-quick up wg0 || { echo "Failed to restart WireGuard"; log_message "Failed to restart WireGuard after adding $username"; return; }
}

# Function to remove a user
remove_user() {
    read -p "Enter username to remove: " username
    if grep -q "^$username," $USER_DB; then
        sed -i "/^$username,/d" $USER_DB
        sed -i "/PublicKey = $(cat $CONFIG_DIR/${username}_public.key)/,+1d" $CONFIG_DIR/wg0.conf
        rm -f $CONFIG_DIR/${username}*.key $CONFIG_DIR/${username}.conf
        log_message "User $username removed successfully."
        echo "User $username removed successfully."
        wg-quick down wg0 && wg-quick up wg0 || { echo "Failed to restart WireGuard"; log_message "Failed to restart WireGuard after removing $username"; return; }
    else
        echo "User $username not found."
    fi
}

# Function to list all users
list_users() {
    echo "Current users:"
    cat $USER_DB
}

# Check if the script is being run for installation
if [ "$1" = "install" ]; then
    install_script
fi

# Main menu
while true; do
    echo ""
    echo "WireGuard VPN Management"
    echo "1. Install WireGuard"
    echo "2. Add new user"
    echo "3. Remove user"
    echo "4. List users"
    echo "5. Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1) install_wireguard ;;
        2) add_user ;;
        3) remove_user ;;
        4) list_users ;;
        5) exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
done
