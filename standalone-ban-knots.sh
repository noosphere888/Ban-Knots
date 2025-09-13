#!/bin/bash

# Bitcoin Core Knots Node Ban Script
# This script identifies and bans/disconnects Bitcoin Knots nodes
# Works with any Bitcoin Core node with RPC enabled

# Default values
RPC_HOST="127.0.0.1"
RPC_PORT="8332"
RPC_USER=""
RPC_PASSWORD=""
BAN_DURATION=$((60*60*24*365*5)) # 5 years in seconds
DISCONNECT_ONLY=false
DRY_RUN=false
CONFIG_FILE=""
CRON_INTERVAL=10  # minutes
INSTALL_CRON=false
UNINSTALL_CRON=false

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -h, --host HOST           RPC host (default: 127.0.0.1)
    -p, --port PORT           RPC port (default: 8332)
    -u, --user USER           RPC username (required)
    -P, --password PASS       RPC password (required)
    -d, --duration SECONDS    Ban duration in seconds (default: 5 years)
    -D, --disconnect-only     Only disconnect, don't ban
    -n, --dry-run            Show what would be done without doing it
    -c, --config FILE        Read settings from config file
    --install-cron           Install as cron job (runs every 10 minutes)
    --uninstall-cron         Remove cron job
    --cron-interval MIN      Set cron interval in minutes (default: 10)
    -H, --help               Show this help message

Config file format (one per line):
    rpc_host=127.0.0.1
    rpc_port=8332
    rpc_user=username
    rpc_password=password
    ban_duration=157680000
    disconnect_only=false

Example:
    $0 -u myuser -P mypassword
    $0 -c ~/.bitcoin/ban-knots.conf
    $0 -h 192.168.1.100 -u user -P pass --dry-run
    $0 -c ~/.bitcoin/ban-knots.conf --install-cron
    $0 --uninstall-cron

EOF
    exit 1
}

# Function to read config file
read_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                rpc_host) RPC_HOST="$value" ;;
                rpc_port) RPC_PORT="$value" ;;
                rpc_user) RPC_USER="$value" ;;
                rpc_password) RPC_PASSWORD="$value" ;;
                ban_duration) BAN_DURATION="$value" ;;
                disconnect_only) DISCONNECT_ONLY="$value" ;;
            esac
        done < "$config_file"
    else
        echo "Error: Config file not found: $config_file"
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            RPC_HOST="$2"
            shift 2
            ;;
        -p|--port)
            RPC_PORT="$2"
            shift 2
            ;;
        -u|--user)
            RPC_USER="$2"
            shift 2
            ;;
        -P|--password)
            RPC_PASSWORD="$2"
            shift 2
            ;;
        -d|--duration)
            BAN_DURATION="$2"
            shift 2
            ;;
        -D|--disconnect-only)
            DISCONNECT_ONLY=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -c|--config)
            read_config "$2"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --install-cron)
            INSTALL_CRON=true
            shift
            ;;
        --uninstall-cron)
            UNINSTALL_CRON=true
            shift
            ;;
        --cron-interval)
            CRON_INTERVAL="$2"
            shift 2
            ;;
        -H|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Handle cron operations
if [[ "$UNINSTALL_CRON" == "true" ]]; then
    echo "Removing ban-knots from crontab..."
    crontab -l 2>/dev/null | grep -v "standalone-ban-knots.sh" | crontab -
    echo "Cron job removed successfully"
    exit 0
fi

if [[ "$INSTALL_CRON" == "true" ]]; then
    if [[ -z "$CONFIG_FILE" && ( -z "$RPC_USER" || -z "$RPC_PASSWORD" ) ]]; then
        echo "Error: You must specify either a config file (-c) or RPC credentials (-u/-P) for cron installation"
        exit 1
    fi
    
    SCRIPT_PATH=$(realpath "$0")
    
    # Build cron command
    if [[ -n "$CONFIG_FILE" ]]; then
        CONFIG_PATH=$(realpath "$CONFIG_FILE")
        CRON_CMD="$SCRIPT_PATH -c $CONFIG_PATH"
    else
        CRON_CMD="$SCRIPT_PATH -u $RPC_USER -P $RPC_PASSWORD"
        [[ "$RPC_HOST" != "127.0.0.1" ]] && CRON_CMD="$CRON_CMD -h $RPC_HOST"
        [[ "$RPC_PORT" != "8332" ]] && CRON_CMD="$CRON_CMD -p $RPC_PORT"
    fi
    
    # Add logging
    CRON_CMD="$CRON_CMD >> /tmp/ban-knots.log 2>&1"
    
    # Install cron job
    echo "Installing cron job to run every $CRON_INTERVAL minutes..."
    
    # Remove existing entries to avoid duplicates
    crontab -l 2>/dev/null | grep -v "standalone-ban-knots.sh" > /tmp/cron_temp
    
    # Add new entry
    echo "*/$CRON_INTERVAL * * * * $CRON_CMD" >> /tmp/cron_temp
    
    # Install new crontab
    crontab /tmp/cron_temp
    rm /tmp/cron_temp
    
    echo "Cron job installed successfully!"
    echo "Command: $CRON_CMD"
    echo "Check logs at: /tmp/ban-knots.log"
    echo ""
    echo "To view cron jobs: crontab -l"
    echo "To remove cron job: $0 --uninstall-cron"
    exit 0
fi

# Check required parameters for normal operation
if [[ -z "$RPC_USER" || -z "$RPC_PASSWORD" ]]; then
    echo "Error: RPC username and password are required"
    usage
fi

# Function to execute bitcoin-cli commands
bitcoin_cli() {
    bitcoin-cli \
        -rpcconnect="$RPC_HOST" \
        -rpcport="$RPC_PORT" \
        -rpcuser="$RPC_USER" \
        -rpcpassword="$RPC_PASSWORD" \
        "$@"
}

echo "=== Bitcoin Knots Node Ban Script ==="
echo "RPC Host: $RPC_HOST:$RPC_PORT"
echo "Disconnect Only: $DISCONNECT_ONLY"
echo "Dry Run: $DRY_RUN"
echo ""

# Check if we can connect to the node
if ! bitcoin_cli getblockcount &>/dev/null; then
    echo "Error: Cannot connect to Bitcoin node at $RPC_HOST:$RPC_PORT"
    echo "Please check your RPC credentials and connection settings"
    exit 1
fi

echo "Successfully connected to Bitcoin node"
echo ""

# Get all peers
echo "Fetching peer information..."
PEERS_JSON=$(bitcoin_cli getpeerinfo)

if [[ -z "$PEERS_JSON" ]]; then
    echo "Error: Failed to get peer information"
    exit 1
fi

# Find Knots nodes
KNOTS_NODES=$(echo "$PEERS_JSON" | jq -r '.[] | select(.subver | contains("Knots")) | {addr: .addr, id: .id, subver: .subver}')

if [[ -z "$KNOTS_NODES" ]]; then
    echo "No Knots nodes found among current peers"
    exit 0
fi

# Count Knots nodes
KNOTS_COUNT=$(echo "$KNOTS_NODES" | jq -s 'length')
echo "Found $KNOTS_COUNT Knots node(s)"
echo ""

# Process each Knots node
echo "$KNOTS_NODES" | jq -c '.' | while read -r node; do
    addr=$(echo "$node" | jq -r '.addr')
    id=$(echo "$node" | jq -r '.id')
    subver=$(echo "$node" | jq -r '.subver')
    base_addr=$(echo "$addr" | sed 's/:.*//' | sed 's/\[//g' | sed 's/\]//g')

    echo "Processing: $addr ($subver)"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$DISCONNECT_ONLY" == "true" ]]; then
            echo "  Status: [DRY RUN] Would disconnect node ID $id"
        else
            echo "  Status: [DRY RUN] Would disconnect and ban IP $base_addr"
        fi
    else
        echo "  Action: Disconnect node ID $id"
        if bitcoin_cli disconnectnode "" "$id" 2>/dev/null; then
            echo "  Status: Disconnected successfully"
        else
            echo "  Status: Failed to disconnect"
        fi

        if [[ "$DISCONNECT_ONLY" == "false" ]]; then
            echo "  Action: Ban IP $base_addr for $BAN_DURATION seconds"
            if bitcoin_cli setban "$base_addr" "add" "$BAN_DURATION" 2>/dev/null; then
                echo "  Status: Banned successfully"
            else
                echo "  Status: Failed to ban (may already be banned)"
            fi
        fi
    fi
    echo ""
done

# Show current ban list summary
if [[ "$DISCONNECT_ONLY" == "false" && "$DRY_RUN" == "false" ]]; then
    echo "Current ban list summary:"
    BAN_COUNT=$(bitcoin_cli listbanned | jq 'length')
    echo "Total banned addresses: $BAN_COUNT"
fi

echo "Script completed"
