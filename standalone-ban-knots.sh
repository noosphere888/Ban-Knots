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
COOKIE_PATH=""
DEFAULT_COOKIE_PATHS=(
    "$HOME/.bitcoin/.cookie"
    "$HOME/Library/Application Support/Bitcoin/.cookie"
    "/var/lib/bitcoind/.cookie"
    "$HOME/umbrel/app-data/bitcoin/data/bitcoin/.cookie"
)
DEFAULT_BITCOIN_CONF_PATHS=(
    "$HOME/.bitcoin/bitcoin.conf"
    "$HOME/Library/Application Support/Bitcoin/bitcoin.conf"
    "/etc/bitcoin/bitcoin.conf"
)

# Detect if running on Start9
IS_START9=false
START9_CONTAINER_PREFIX=""
if [[ -f "/etc/embassy/config.yaml" ]] || [[ -d "/embassy-data" ]]; then
    IS_START9=true
    # Start9 runs Bitcoin Core in a podman container
    # Don't use -it flag as it requires a TTY (breaks in cron)
    START9_CONTAINER_PREFIX="sudo podman exec bitcoind.embassy"
fi

# Detect if running on Umbrel
IS_UMBREL=false
UMBREL_CONTAINER_PREFIX="docker exec bitcoin_app_1"
if uname -a | grep -qi "umbrel" ; then
    IS_UMBREL=true
fi

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

By default, uses Bitcoin Core cookie authentication if available.
Falls back to bitcoin.conf, then manual credentials.

Options:
    -h, --host HOST           RPC host (default: 127.0.0.1)
    -p, --port PORT           RPC port (default: 8332)
    -u, --user USER           RPC username (overrides auto-detection)
    -P, --password PASS       RPC password (overrides auto-detection)
    --cookie-path PATH        Path to .cookie file (default: auto-detect)
    -d, --duration SECONDS    Ban duration in seconds (default: 5 years)
    -D, --disconnect-only     Only disconnect, don't ban
    -n, --dry-run            Show what would be done without doing it
    -c, --config FILE        Read settings from config file
    --install-cron           Install as cron job (runs every 10 minutes)
    --uninstall-cron         Remove cron job
    --cron-interval MIN      Set cron interval in minutes (default: 10)
    --umbrel                 Umbrel compatibility (default: auto-detect)
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
                rpc_password) RPC_PASSWORD="$(grep "rpc_password" "$config_file" | cut -d '=' -f 2-)" ;;
                ban_duration) BAN_DURATION="$value" ;;
                disconnect_only) DISCONNECT_ONLY="$value" ;;
            esac
        done < "$config_file"
    else
        echo "Error: Config file not found: $config_file"
        exit 1
    fi
}

# Function to find cookie file in default locations
find_cookie_file() {
    for path in "${DEFAULT_COOKIE_PATHS[@]}"; do
        if [[ -r "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Function to read and parse cookie auth
read_cookie_auth() {
    local cookie_file="$1"
    if [[ -r "$cookie_file" ]]; then
        IFS=':' read -r RPC_USER RPC_PASSWORD < "$cookie_file"
        return 0
    fi
    return 1
}

# Function to find bitcoin.conf in default locations
find_bitcoin_conf() {
    for path in "${DEFAULT_BITCOIN_CONF_PATHS[@]}"; do
        if [[ -r "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Function to parse bitcoin.conf for RPC settings
parse_bitcoin_conf() {
    local bitcoin_conf="$1"
    if [[ -r "$bitcoin_conf" ]]; then
        while IFS='=' read -r key value; do
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            case "$key" in
                rpcuser) RPC_USER="$value" ;;
                rpcpassword) RPC_PASSWORD="$value" ;;
                rpcport) RPC_PORT="${value:-8332}" ;;
                rpcbind|rpcconnect) 
                    # Extract just the IP, ignore port if present
                    RPC_HOST=$(echo "$value" | cut -d':' -f1)
                    ;;
            esac
        done < "$bitcoin_conf"
        # Check if we got both user and password
        if [[ -n "$RPC_USER" && -n "$RPC_PASSWORD" ]]; then
            return 0
        fi
    fi
    return 1
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
        --umbrel)
            IS_UMBREL=true
            shift
            ;;
        --cookie-path)
            COOKIE_PATH="$2"
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
    # For cron installation, we just need to ensure the script can authenticate somehow
    # It will use the same auth discovery when it runs
    NEEDS_CREDS=false
    
    # Check if manual credentials provided
    if [[ -n "$RPC_USER" && -n "$RPC_PASSWORD" ]]; then
        NEEDS_CREDS=false
    # Check if config file provided
    elif [[ -n "$CONFIG_FILE" ]]; then
        NEEDS_CREDS=false
    # Check if cookie path specified
    elif [[ -n "$COOKIE_PATH" ]]; then
        NEEDS_CREDS=false
    # Check if cookie exists in default location
    elif find_cookie_file >/dev/null; then
        NEEDS_CREDS=false
    # Check if bitcoin.conf exists
    elif find_bitcoin_conf >/dev/null; then
        NEEDS_CREDS=false
    else
        NEEDS_CREDS=true
    fi
    
    if [[ "$NEEDS_CREDS" == "true" ]]; then
        echo "Error: No authentication method available for cron installation"
        echo "Please ensure one of the following:"
        echo "  - Bitcoin Core .cookie file exists"
        echo "  - bitcoin.conf with RPC credentials exists"
        echo "  - Specify credentials with -u/-P"
        echo "  - Specify a config file with -c"
        exit 1
    fi
    
    SCRIPT_PATH=$(realpath "$0")
    
    # Build cron command
    if [[ -n "$CONFIG_FILE" ]]; then
        CONFIG_PATH=$(realpath "$CONFIG_FILE")
        CRON_CMD="$SCRIPT_PATH -c $CONFIG_PATH"
    elif [[ -n "$RPC_USER" && -n "$RPC_PASSWORD" ]]; then
        CRON_CMD="$SCRIPT_PATH -u $RPC_USER -P $RPC_PASSWORD"
        [[ "$RPC_HOST" != "127.0.0.1" ]] && CRON_CMD="$CRON_CMD -h $RPC_HOST"
        [[ "$RPC_PORT" != "8332" ]] && CRON_CMD="$CRON_CMD -p $RPC_PORT"
    elif [[ -n "$COOKIE_PATH" ]]; then
        COOKIE_PATH_ABS=$(realpath "$COOKIE_PATH")
        CRON_CMD="$SCRIPT_PATH --cookie-path $COOKIE_PATH_ABS"
    else
        # No explicit auth specified, script will auto-detect
        CRON_CMD="$SCRIPT_PATH"
    fi
    
    # Propagate Umbrel mode, if needed
    if [[ "IS_UMBREL" == "true" ]]; then
        CRON_CMD="$CRON_CMD --umbrel"
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

# Special handling for Start9
if [[ "$IS_START9" == "true" && -z "$RPC_USER" && -z "$RPC_PASSWORD" ]]; then
    echo ""
    echo "=== Start9 Detected ==="
    echo "Start9 requires manual RPC credentials from the web interface."
    echo ""
    echo "To get your RPC credentials:"
    echo "1. Open your Start9 web interface"
    echo "2. Go to: Services → Bitcoin Core → Config → RPC Settings"
    echo "3. Copy your RPC username and password"
    echo "4. Run this script with: $0 -u <username> -P <password>"
    echo ""
    echo "For automatic operation, create a config file:"
    echo "  echo 'rpc_user=<your-username>' > ~/.bitcoin/ban-knots.conf"
    echo "  echo 'rpc_password=<your-password>' >> ~/.bitcoin/ban-knots.conf"
    echo "  $0 -c ~/.bitcoin/ban-knots.conf --install-cron"
    echo ""
    exit 1
fi

# Authentication flow - try multiple methods in order
if [[ -z "$RPC_USER" || -z "$RPC_PASSWORD" ]]; then
    echo "No manual credentials provided, trying auto-detection..."
    
    # 1. Try specified cookie path
    if [[ -n "$COOKIE_PATH" ]]; then
        echo "Trying specified cookie file: $COOKIE_PATH"
        if read_cookie_auth "$COOKIE_PATH"; then
            echo "Using cookie authentication from $COOKIE_PATH"
        else
            echo "Error: Cannot read cookie file: $COOKIE_PATH"
            exit 1
        fi
    
    # 2. Try finding cookie in default locations
    elif FOUND_COOKIE=$(find_cookie_file); then
        echo "Found cookie file: $FOUND_COOKIE"
        if read_cookie_auth "$FOUND_COOKIE"; then
            echo "Using cookie authentication"
        else
            echo "Error: Cannot read cookie file: $FOUND_COOKIE"
            exit 1
        fi
    
    # 3. Try bitcoin.conf
    elif FOUND_CONF=$(find_bitcoin_conf); then
        echo "Found bitcoin.conf: $FOUND_CONF"
        if parse_bitcoin_conf "$FOUND_CONF"; then
            echo "Using credentials from bitcoin.conf"
        else
            echo "Error: No RPC credentials found in bitcoin.conf"
            exit 1
        fi
    
    # 4. Error - no auth method available
    else
        echo "Error: No authentication method available"
        echo "Please provide credentials via:"
        echo "  - Command line: -u USER -P PASS"
        echo "  - Cookie file: ensure .cookie exists in standard location"
        echo "  - Bitcoin config: ensure bitcoin.conf has rpcuser/rpcpassword"
        exit 1
    fi
else
    echo "Using provided credentials"
fi

# Function to execute bitcoin-cli commands
bitcoin_cli() {
    local cmd="bitcoin-cli"
    
    # Use container execution for Start9
    if [[ "$IS_START9" == "true" ]]; then
        $START9_CONTAINER_PREFIX bitcoin-cli \
            -rpcconnect="$RPC_HOST" \
            -rpcport="$RPC_PORT" \
            -rpcuser="$RPC_USER" \
            -rpcpassword="$RPC_PASSWORD" \
            "$@"
    elif [[ "$IS_UMBREL" == "true" ]]; then
        $UMBREL_CONTAINER_PREFIX bitcoin-cli \
            -rpcconnect="$RPC_HOST" \
            -rpcport="$RPC_PORT" \
            -rpcuser="$RPC_USER" \
            -rpcpassword="$RPC_PASSWORD" \
            "$@"
    else
        bitcoin-cli \
            -rpcconnect="$RPC_HOST" \
            -rpcport="$RPC_PORT" \
            -rpcuser="$RPC_USER" \
            -rpcpassword="$RPC_PASSWORD" \
            "$@"
    fi
}

echo "=== Bitcoin Knots Node Ban Script ==="
if [[ "$IS_START9" == "true" ]]; then
    echo "Platform: Start9 (using podman container)"
elif [[ "$IS_UMBREL" == "true" ]]; then
    echo "Platform: Umbrel (using Docker container)"
fi
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
    
    # Extract IP address (remove port)
    base_addr=$(echo "$addr" | sed 's/:.*//' | sed 's/\[//g' | sed 's/\]//g')
    
    echo "Processing: $addr ($subver)"
    
    if [[ "$DISCONNECT_ONLY" == "true" ]]; then
        # Just disconnect
        echo "  Action: Disconnect (ID: $id)"
        if [[ "$DRY_RUN" == "false" ]]; then
            if bitcoin_cli disconnectnode "" "$id" 2>/dev/null; then
                echo "  Status: Disconnected successfully"
            else
                echo "  Status: Failed to disconnect"
            fi
        else
            echo "  Status: [DRY RUN] Would disconnect"
        fi
    else
        # Disconnect and ban
        echo "  Action: Disconnect and Ban"
        echo "  Ban Duration: $BAN_DURATION seconds"
        
        if [[ "$DRY_RUN" == "false" ]]; then
            # First disconnect
            bitcoin_cli disconnectnode "" "$id" 2>/dev/null
            
            # Then ban
            if bitcoin_cli setban "$base_addr" "add" "$BAN_DURATION" 2>/dev/null; then
                echo "  Status: Banned successfully"
            else
                echo "  Status: Failed to ban (may already be banned)"
            fi
        else
            echo "  Status: [DRY RUN] Would disconnect and ban"
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
