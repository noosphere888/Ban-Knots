#!/bin/bash

# Bitcoin Core Knots Node Ban Script v1.2.1
# This script identifies and bans/disconnects Bitcoin Knots nodes
# Works with any Bitcoin Core node with RPC enabled
# 
# Detection methods:
# 1. User agent matching (default)
# 2. Historical IP banlist (optional)

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
USE_EXTERNAL_BANLIST=false  # Don't download external list by default (privacy)
BANLIST_URL="https://raw.githubusercontent.com/aeonBTC/Knots-Banlist/main/knownknots.txt"
BANLIST_FILE="$HOME/.bitcoin/knots-banlist.txt"
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
    -e, --external-ban-list  Enable external IP banlist download (privacy note: downloads from GitHub)
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
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --host requires an argument"
                usage
            fi
            RPC_HOST="$2"
            shift 2
            ;;
        -p|--port)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --port requires an argument"
                usage
            fi
            RPC_PORT="$2"
            shift 2
            ;;
        -u|--user)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --user requires an argument"
                usage
            fi
            RPC_USER="$2"
            shift 2
            ;;
        -P|--password)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --password requires an argument"
                usage
            fi
            RPC_PASSWORD="$2"
            shift 2
            ;;
        -d|--duration)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --duration requires an argument"
                usage
            fi
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
        -e|--external-ban-list)
            USE_EXTERNAL_BANLIST=true
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
    
    # Propagate Umbrel mode, if needed - FIX: Add $ to variable
    if [[ "$IS_UMBREL" == "true" ]]; then
        CRON_CMD="$CRON_CMD --umbrel"
    fi
    
    # Propagate external banlist flag if enabled
    if [[ "$USE_EXTERNAL_BANLIST" == "true" ]]; then
        CRON_CMD="$CRON_CMD --external-ban-list"
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

# Update IP banlist from upstream and merge with local discoveries
update_banlist() {
    local need_update=false
    local temp_file="/tmp/knots-upstream-$$.txt"
    
    # Create directory if needed
    local banlist_dir=$(dirname "$BANLIST_FILE")
    [[ ! -d "$banlist_dir" ]] && mkdir -p "$banlist_dir"
    
    # Only download external list if flag is set
    if [[ "$USE_EXTERNAL_BANLIST" != true ]]; then
        # Just create empty file if doesn't exist
        [[ ! -f "$BANLIST_FILE" ]] && touch "$BANLIST_FILE"
        return
    fi
    
    # Check if we need to update from upstream
    if [[ ! -f "$BANLIST_FILE" ]]; then
        need_update=true
    else
        local file_age=$(( $(date +%s) - $(stat -f %m "$BANLIST_FILE" 2>/dev/null || stat -c %Y "$BANLIST_FILE" 2>/dev/null || echo 0) ))
        if (( file_age > 604800 )); then  # 7 days
            need_update=true
        fi
    fi
    
    if [[ "$need_update" == true ]]; then
        echo "Updating Knots IP banlist from upstream..."
        if curl -s "$BANLIST_URL" -o "$temp_file" 2>/dev/null || wget -q "$BANLIST_URL" -O "$temp_file" 2>/dev/null; then
            # Merge upstream with existing local discoveries
            if [[ -f "$BANLIST_FILE" ]]; then
                # Extract just IPs from existing file (in case it has timestamps)
                {
                    cat "$temp_file"
                    grep -E "^[0-9a-fA-F:.]+[|$]?" "$BANLIST_FILE" | cut -d'|' -f1
                } | sort -u > "${BANLIST_FILE}.tmp"
                mv "${BANLIST_FILE}.tmp" "$BANLIST_FILE"
                echo "Updated banlist: $(wc -l < "$BANLIST_FILE") total IPs (upstream + local)"
            else
                mv "$temp_file" "$BANLIST_FILE"
                echo "Created banlist: $(wc -l < "$BANLIST_FILE") IPs from upstream"
            fi
            rm -f "$temp_file"
        else
            echo "Failed to download upstream banlist, using existing"
        fi
    fi
}

# Check if IP is in banlist
is_banned_ip() {
    local ip=$1
    [[ -f "$BANLIST_FILE" ]] && grep -q "^${ip}$" "$BANLIST_FILE"
}

# Add newly discovered Knots IP to banlist
add_to_banlist() {
    local ip=$1
    local detection_method=$2
    
    # Check if IP already in banlist
    if ! grep -q "^${ip}$" "$BANLIST_FILE"; then
        echo "$ip" >> "$BANLIST_FILE"
        echo "  Added new discovery to banlist"
        
        # Optional: Keep a log of discoveries with metadata
        local log_file="${BANLIST_FILE}.log"
        local timestamp=$(date -u +"%Y-%m-%d %H:%M:%S")
        echo "${timestamp}|${ip}|${detection_method}" >> "$log_file"
    fi
}

echo "=== Bitcoin Knots Node Ban Script v1.2.1 ==="
if [[ "$IS_START9" == "true" ]]; then
    echo "Platform: Start9 (using podman container)"
elif [[ "$IS_UMBREL" == "true" ]]; then
    echo "Platform: Umbrel (using Docker container)"
fi
echo "RPC Host: $RPC_HOST:$RPC_PORT"
echo "Disconnect Only: $DISCONNECT_ONLY"
echo "Dry Run: $DRY_RUN"
echo "External Ban List: $USE_EXTERNAL_BANLIST"
echo ""

# Check if we can connect to the node
if ! bitcoin_cli getblockcount &>/dev/null; then
    echo "Error: Cannot connect to Bitcoin node at $RPC_HOST:$RPC_PORT"
    echo "Please check your RPC credentials and connection settings"
    exit 1
fi

echo "Successfully connected to Bitcoin node"
echo ""

# Update banlist if using external list
update_banlist
echo ""

# Get all peers
echo "Fetching peer information..."
PEERS_JSON=$(bitcoin_cli getpeerinfo)

if [[ -z "$PEERS_JSON" ]]; then
    echo "Error: Failed to get peer information"
    exit 1
fi

# Statistics
TOTAL_PEERS=$(echo "$PEERS_JSON" | jq 'length')
KNOTS_BY_UA=0
KNOTS_BY_IP=0
TOTAL_KNOTS=0

echo "Total peers: $TOTAL_PEERS"
echo ""

# Detect Knots nodes using all methods
KNOTS_NODES=""

while IFS= read -r peer; do
    addr=$(echo "$peer" | jq -r '.addr')
    id=$(echo "$peer" | jq -r '.id')
    subver=$(echo "$peer" | jq -r '.subver // ""')
    services=$(echo "$peer" | jq -r '.services // ""')
    
    # Extract IP (handle IPv4, IPv6, and onion addresses)
    if [[ "$addr" =~ ^\[([^\]]+)\]:[0-9]+$ ]]; then
        # IPv6 format: [::1]:8333
        base_addr="${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ ^([^:]+):[0-9]+$ ]]; then
        # IPv4 or onion format: 1.2.3.4:8333
        base_addr="${BASH_REMATCH[1]}"
    else
        # No port specified
        base_addr="$addr"
    fi
    
    is_knots=false
    detection_methods=""
    
    # Method 1: User agent detection
    if echo "$subver" | grep -qiE "(knots|bitcoinknots)"; then
        is_knots=true
        detection_methods="User-Agent"
        ((KNOTS_BY_UA++))
    fi
    
    # Method 2: IP banlist detection (if using external list)
    if [[ "$USE_EXTERNAL_BANLIST" == true ]] && is_banned_ip "$base_addr"; then
        is_knots=true
        [[ -n "$detection_methods" ]] && detection_methods="${detection_methods}+Known-IP" || detection_methods="Known-IP"
        ((KNOTS_BY_IP++))
    fi
    
    # Add to Knots nodes list if detected
    if [[ "$is_knots" == true ]]; then
        node_json=$(jq -n --arg addr "$addr" --arg id "$id" --arg subver "$subver" --arg detect "$detection_methods" \
                   '{addr: $addr, id: $id, subver: $subver, detection: $detect}')
        if [[ -z "$KNOTS_NODES" ]]; then
            KNOTS_NODES="$node_json"
        else
            KNOTS_NODES="${KNOTS_NODES}\n${node_json}"
        fi
        ((TOTAL_KNOTS++))
    fi
done < <(echo "$PEERS_JSON" | jq -c '.[]')

if [[ -z "$KNOTS_NODES" ]]; then
    echo "No Knots nodes found among current peers"
    echo ""
    echo "Detection summary:"
    echo "  Checked with user agent: $TOTAL_PEERS peers"
    if [[ "$USE_EXTERNAL_BANLIST" == true ]]; then
        echo "  Checked against IP banlist: $(wc -l < "$BANLIST_FILE" 2>/dev/null || echo 0) IPs"
    fi
    exit 0
fi

# Summary
echo "Found $TOTAL_KNOTS Knots node(s):"
echo "  By user agent: $KNOTS_BY_UA"
if [[ "$USE_EXTERNAL_BANLIST" == true ]]; then
    echo "  By IP list: $KNOTS_BY_IP"
fi
echo ""

# Process each Knots node
echo -e "$KNOTS_NODES" | while IFS= read -r node_json; do
    [[ -z "$node_json" ]] && continue
    
    addr=$(echo "$node_json" | jq -r '.addr')
    id=$(echo "$node_json" | jq -r '.id')
    subver=$(echo "$node_json" | jq -r '.subver')
    detection=$(echo "$node_json" | jq -r '.detection')
    
    # Extract IP address (remove port)
    # Extract IP (handle IPv4, IPv6, and onion addresses)
    if [[ "$addr" =~ ^\[([^\]]+)\]:[0-9]+$ ]]; then
        # IPv6 format: [::1]:8333
        base_addr="${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ ^([^:]+):[0-9]+$ ]]; then
        # IPv4 or onion format: 1.2.3.4:8333
        base_addr="${BASH_REMATCH[1]}"
    else
        # No port specified
        base_addr="$addr"
    fi
    
    echo "Processing: $addr ($subver)"
    echo "  Detection: $detection"
    
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
                # Add to local discovered list
                add_to_banlist "$base_addr" "$detection"
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
    
    # Show banlist info
    if [[ -f "$BANLIST_FILE" ]]; then
        BANLIST_COUNT=$(wc -l < "$BANLIST_FILE" | tr -d ' ')
        echo "Knots IP banlist: $BANLIST_COUNT total IPs"
        
        # Show recent discoveries if log exists
        if [[ -f "${BANLIST_FILE}.log" ]]; then
            RECENT_DISCOVERIES=$(tail -5 "${BANLIST_FILE}.log" | wc -l | tr -d ' ')
            echo "Recent discoveries: $RECENT_DISCOVERIES (see ${BANLIST_FILE}.log)"
        fi
    fi
fi

echo "Script completed"