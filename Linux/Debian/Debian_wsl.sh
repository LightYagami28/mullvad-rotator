#!/usr/bin/env bash
#
# mullvad-rotator - Automatic Mullvad VPN server rotation
# Optimized for Debian 13 (Trixie)
#

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="mullvad-rotator"
readonly CONFIG_FILE="/etc/mullvad-rotator.conf"
readonly LOCKFILE="/run/mullvad-rotator.lock"
readonly DEFAULT_LOG_FILE="/var/log/mullvad-rotator.log"

# Default configuration
RECONNECT_INTERVAL=30
COUNTRY_CODE="any"
LOG_TO_FILE=true
LOG_FILE="$DEFAULT_LOG_FILE"
MAX_RETRIES=5
INITIAL_BACKOFF=10
BACKOFF_MULTIPLIER=2
TUNNEL_PROTOCOL="wireguard"
INTERACTIVE_MODE=false
SETUP_MODE=false

# Runtime state
RETRY_COUNT=0
BACKOFF_DELAY=0
RUNNING=true

# Colors for terminal output
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}           Mullvad VPN Server Rotator v${SCRIPT_VERSION}           ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

print_section() {
    echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info() { echo -e "${BLUE}→${NC} $1"; }

log() {
    local level="${2:-INFO}"
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $1"
    
    case "$level" in
        ERROR) echo -e "${RED}$message${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}$message${NC}" ;;
        *)     echo "$message" ;;
    esac
    
    if [[ "$LOG_TO_FILE" == true && -w "$LOG_FILE" ]]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

die() {
    print_error "$1"
    exit "${2:-1}"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script requires root privileges. Please run with sudo." 1
    fi
}

require_cmd() {
    local cmd="$1"
    local package="${2:-$1}"
    
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command '$cmd' not found. Install it with: apt install $package" 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    local tmp_config
    tmp_config=$(mktemp)
    cat > "$tmp_config" << EOF
# Mullvad Rotator Configuration
# Generated on $(date)

# Time between server rotations (in seconds)
RECONNECT_INTERVAL=$RECONNECT_INTERVAL

# Target country code (use 'any' for random worldwide)
COUNTRY_CODE="$COUNTRY_CODE"

# Logging settings
LOG_TO_FILE=$LOG_TO_FILE
LOG_FILE="$LOG_FILE"

# Retry behavior on connection failure
MAX_RETRIES=$MAX_RETRIES
INITIAL_BACKOFF=$INITIAL_BACKOFF
BACKOFF_MULTIPLIER=$BACKOFF_MULTIPLIER

# VPN tunnel protocol (wireguard or openvpn)
TUNNEL_PROTOCOL="$TUNNEL_PROTOCOL"
EOF
    chmod 600 "$tmp_config"
    mv "$tmp_config" "$CONFIG_FILE"
    print_success "Configuration saved to $CONFIG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MULLVAD INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════

mullvad_get_status() {
    local status
    status=$(mullvad status 2>/dev/null) || echo "Unknown"
    
    if echo "$status" | grep -qi "disconnected"; then
        echo "disconnected"
    elif echo "$status" | grep -qi "connecting"; then
        echo "connecting"
    elif echo "$status" | grep -qi "connected"; then
        echo "connected"
    else
        echo "unknown"
    fi
}

mullvad_get_location() {
    local status
    status=$(mullvad status 2>/dev/null) || { echo "none"; return; }
    
    # Extract relay info from status output
    # Format: "Connected to se-got-wg-001 in Gothenburg, Sweden"
    local location
    location=$(echo "$status" | grep -oP 'in \K[^,^.]+, [^,^.]+' | head -1) || true
    
    if [[ -n "$location" ]]; then
        echo "$location"
    else
        echo "none"
    fi
}

mullvad_get_country_code() {
    local status
    status=$(mullvad status 2>/dev/null) || { echo "none"; return; }
    
    # Extract country code from relay name (e.g., "se-got-wg-001" → "se")
    local relay
    relay=$(echo "$status" | grep -oP 'Connected to \K[a-z]{2}' | head -1) || true
    
    if [[ -n "$relay" ]]; then
        echo "$relay"
    else
        echo "none"
    fi
}

mullvad_get_ip() {
    local status
    status=$(mullvad status 2>/dev/null) || { echo "unknown"; return; }
    
    local ip
    ip=$(echo "$status" | grep -oP 'IPv4: \K[0-9.]+' | head -1) || true
    
    if [[ -n "$ip" ]]; then
        echo "$ip"
    else
        echo "unknown"
    fi
}

mullvad_list_countries() {
    mullvad relay list 2>/dev/null | \
        grep -oP '^[a-z]{2}\s+[A-Za-z ]+' | \
        sort -u
}

mullvad_validate_country() {
    local country="$1"
    
    [[ "$country" == "any" ]] && return 0
    
    local countries
    countries=$(mullvad relay list 2>/dev/null | grep -oP '^[a-z]{2}' | sort -u)
    
    if echo "$countries" | grep -qx "$country"; then
        return 0
    fi
    return 1
}

mullvad_set_relay() {
    local country="$1"
    
    if [[ "$country" == "any" ]]; then
        mullvad relay set location any &>/dev/null
    else
        mullvad relay set location "$country" &>/dev/null
    fi
}

mullvad_set_protocol() {
    local protocol="$1"
    mullvad relay set tunnel-protocol "$protocol" &>/dev/null || true
}

mullvad_connect() {
    mullvad connect &>/dev/null
    
    # Wait for connection with timeout
    local timeout=30
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(mullvad_get_status)
        
        case "$status" in
            connected) return 0 ;;
            connecting) sleep 1; ((elapsed++)) ;;
            *) return 1 ;;
        esac
    done
    
    return 1
}

mullvad_disconnect() {
    mullvad disconnect &>/dev/null || true
    sleep 1
}

mullvad_reconnect() {
    local country="$1"
    
    mullvad_disconnect
    mullvad_set_relay "$country"
    mullvad_connect
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOCKFILE MANAGEMENT (using flock for atomicity)
# ═══════════════════════════════════════════════════════════════════════════════

acquire_lock() {
    exec 200>"$LOCKFILE"
    
    if ! flock -n 200; then
        die "Another instance is already running." 1
    fi
    
    echo $$ >&200
}

release_lock() {
    flock -u 200 2>/dev/null || true
    rm -f "$LOCKFILE" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# SIGNAL HANDLING & CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

cleanup() {
    RUNNING=false
    echo
    log "Shutting down gracefully..."
    
    if command -v mullvad &>/dev/null; then
        log "Disconnecting from Mullvad..."
        mullvad_disconnect
    fi
    
    release_lock
    log "Goodbye!"
    exit 0
}

setup_signals() {
    trap cleanup EXIT INT TERM HUP
}

# ═══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE SETUP WIZARD
# ═══════════════════════════════════════════════════════════════════════════════

wizard_welcome() {
    clear
    print_header
    
    echo -e "Welcome! This wizard will help you set up automatic VPN server rotation."
    echo -e "Your privacy is protected by switching servers regularly.\n"
    echo -e "Press ${BOLD}Enter${NC} to continue or ${BOLD}Ctrl+C${NC} to exit.\n"
    read -r
}

wizard_check_requirements() {
    print_section "Checking Requirements"
    
    local all_ok=true
    
    # Check root
    if [[ $EUID -eq 0 ]]; then
        print_success "Running with administrator privileges"
    else
        print_error "Administrator privileges required"
        all_ok=false
    fi
    
    # Check Mullvad
    if command -v mullvad &>/dev/null; then
        print_success "Mullvad VPN client installed"
        
        # Check if logged in
        if mullvad account get &>/dev/null; then
            print_success "Mullvad account is configured"
        else
            print_warning "Mullvad account not configured"
            echo -e "\n${YELLOW}Please run 'mullvad account login' first.${NC}\n"
            all_ok=false
        fi
    else
        print_error "Mullvad VPN client not found"
        echo -e "\n${YELLOW}Install Mullvad from: https://mullvad.net/download${NC}\n"
        all_ok=false
    fi
    
    # Check flock
    if command -v flock &>/dev/null; then
        print_success "Required utilities available"
    else
        print_error "Missing 'flock' utility (install: apt install util-linux)"
        all_ok=false
    fi
    
    if [[ "$all_ok" != true ]]; then
        echo
        die "Please fix the issues above and run the setup again." 1
    fi
    
    echo
    print_success "All requirements satisfied!"
    echo -e "\nPress ${BOLD}Enter${NC} to continue..."
    read -r
}

wizard_country_selection() {
    print_section "Server Location"
    
    echo "Choose which country's servers to use:"
    echo
    echo -e "  ${BOLD}1)${NC} Any country (maximum privacy - recommended)"
    echo -e "  ${BOLD}2)${NC} Choose a specific country"
    echo
    
    while true; do
        read -rp "Your choice [1-2]: " choice
        
        case "$choice" in
            1)
                COUNTRY_CODE="any"
                print_success "Selected: Any country (worldwide rotation)"
                break
                ;;
            2)
                echo
                echo "Available countries:"
                echo
                
                local countries
                countries=$(mullvad_list_countries)
                
                # Display in columns
                echo "$countries" | column -t 2>/dev/null || echo "$countries"
                
                echo
                read -rp "Enter country code (e.g., 'us', 'de', 'se'): " country_input
                country_input=$(echo "$country_input" | tr '[:upper:]' '[:lower:]')
                
                if mullvad_validate_country "$country_input"; then
                    COUNTRY_CODE="$country_input"
                    print_success "Selected: $COUNTRY_CODE"
                    break
                else
                    print_error "Invalid country code. Please try again."
                fi
                ;;
            *)
                print_warning "Please enter 1 or 2"
                ;;
        esac
    done
    
    echo -e "\nPress ${BOLD}Enter${NC} to continue..."
    read -r
}

wizard_rotation_interval() {
    print_section "Rotation Frequency"
    
    echo "How often should the VPN server change?"
    echo
    echo -e "  ${BOLD}1)${NC} Every 30 seconds  (high rotation - most private)"
    echo -e "  ${BOLD}2)${NC} Every 5 minutes   (balanced)"
    echo -e "  ${BOLD}3)${NC} Every 15 minutes  (low rotation)"
    echo -e "  ${BOLD}4)${NC} Every 30 minutes  (minimal rotation)"
    echo -e "  ${BOLD}5)${NC} Custom interval"
    echo
    
    while true; do
        read -rp "Your choice [1-5]: " choice
        
        case "$choice" in
            1) RECONNECT_INTERVAL=30; break ;;
            2) RECONNECT_INTERVAL=300; break ;;
            3) RECONNECT_INTERVAL=900; break ;;
            4) RECONNECT_INTERVAL=1800; break ;;
            5)
                read -rp "Enter interval in seconds (minimum 10): " custom_interval
                if [[ "$custom_interval" =~ ^[0-9]+$ ]] && [[ "$custom_interval" -ge 10 ]]; then
                    RECONNECT_INTERVAL="$custom_interval"
                    break
                else
                    print_error "Please enter a number of at least 10 seconds."
                fi
                ;;
            *)
                print_warning "Please enter a number between 1 and 5"
                ;;
        esac
    done
    
    local human_interval
    if [[ $RECONNECT_INTERVAL -lt 60 ]]; then
        human_interval="${RECONNECT_INTERVAL} seconds"
    elif [[ $RECONNECT_INTERVAL -lt 3600 ]]; then
        human_interval="$((RECONNECT_INTERVAL / 60)) minutes"
    else
        human_interval="$((RECONNECT_INTERVAL / 3600)) hours"
    fi
    
    print_success "Rotation interval: $human_interval"
    
    echo -e "\nPress ${BOLD}Enter${NC} to continue..."
    read -r
}

wizard_logging() {
    print_section "Activity Logging"
    
    echo "Would you like to save activity logs?"
    echo -e "(Logs show connection times and server changes)\n"
    echo -e "  ${BOLD}1)${NC} Yes, save logs to a file"
    echo -e "  ${BOLD}2)${NC} No, only show on screen"
    echo
    
    while true; do
        read -rp "Your choice [1-2]: " choice
        
        case "$choice" in
            1)
                LOG_TO_FILE=true
                
                echo
                echo "Where should logs be saved?"
                echo -e "  Default: ${DEFAULT_LOG_FILE}"
                read -rp "Press Enter to accept default, or type a path: " custom_log
                
                if [[ -n "$custom_log" ]]; then
                    LOG_FILE="$custom_log"
                else
                    LOG_FILE="$DEFAULT_LOG_FILE"
                fi
                
                # Create log directory if needed
                local log_dir
                log_dir=$(dirname "$LOG_FILE")
                mkdir -p "$log_dir" 2>/dev/null || true
                
                if touch "$LOG_FILE" 2>/dev/null; then
                    print_success "Logs will be saved to: $LOG_FILE"
                else
                    print_warning "Cannot write to $LOG_FILE, using screen output only"
                    LOG_TO_FILE=false
                fi
                break
                ;;
            2)
                LOG_TO_FILE=false
                print_success "Logs will only appear on screen"
                break
                ;;
            *)
                print_warning "Please enter 1 or 2"
                ;;
        esac
    done
    
    echo -e "\nPress ${BOLD}Enter${NC} to continue..."
    read -r
}

wizard_advanced() {
    print_section "Advanced Settings (Optional)"
    
    echo "Would you like to configure advanced settings?"
    echo -e "(Retry behavior, tunnel protocol)\n"
    echo -e "  ${BOLD}1)${NC} Use recommended defaults"
    echo -e "  ${BOLD}2)${NC} Customize advanced settings"
    echo
    
    read -rp "Your choice [1-2]: " choice
    
    if [[ "$choice" == "2" ]]; then
        echo
        echo "━━━ Tunnel Protocol ━━━"
        echo -e "  ${BOLD}1)${NC} WireGuard (faster, recommended)"
        echo -e "  ${BOLD}2)${NC} OpenVPN (more compatible)"
        echo
        read -rp "Your choice [1-2]: " proto_choice
        
        case "$proto_choice" in
            2) TUNNEL_PROTOCOL="openvpn" ;;
            *) TUNNEL_PROTOCOL="wireguard" ;;
        esac
        
        echo
        echo "━━━ Connection Retries ━━━"
        read -rp "Maximum retry attempts [default: 5]: " max_retry_input
        if [[ "$max_retry_input" =~ ^[0-9]+$ ]] && [[ "$max_retry_input" -ge 1 ]]; then
            MAX_RETRIES="$max_retry_input"
        fi
        
        print_success "Advanced settings configured"
    else
        TUNNEL_PROTOCOL="wireguard"
        MAX_RETRIES=5
        print_success "Using recommended defaults"
    fi
    
    echo -e "\nPress ${BOLD}Enter${NC} to continue..."
    read -r
}

wizard_summary() {
    print_section "Configuration Summary"
    
    local human_interval
    if [[ $RECONNECT_INTERVAL -lt 60 ]]; then
        human_interval="${RECONNECT_INTERVAL} seconds"
    elif [[ $RECONNECT_INTERVAL -lt 3600 ]]; then
        human_interval="$((RECONNECT_INTERVAL / 60)) minutes"
    else
        human_interval="$((RECONNECT_INTERVAL / 3600)) hours"
    fi
    
    echo -e "  Server location:     ${BOLD}${COUNTRY_CODE}${NC}"
    echo -e "  Rotation interval:   ${BOLD}${human_interval}${NC}"
    echo -e "  Tunnel protocol:     ${BOLD}${TUNNEL_PROTOCOL}${NC}"
    echo -e "  Save logs to file:   ${BOLD}${LOG_TO_FILE}${NC}"
    [[ "$LOG_TO_FILE" == true ]] && echo -e "  Log file:            ${BOLD}${LOG_FILE}${NC}"
    echo -e "  Max retry attempts:  ${BOLD}${MAX_RETRIES}${NC}"
    echo
    
    echo "Is this configuration correct?"
    read -rp "[Y/n]: " confirm
    
    if [[ "${confirm,,}" == "n" ]]; then
        return 1
    fi
    
    return 0
}

wizard_save_and_install() {
    print_section "Save & Install"
    
    echo "What would you like to do?"
    echo
    echo -e "  ${BOLD}1)${NC} Save configuration and start now"
    echo -e "  ${BOLD}2)${NC} Save configuration and install as background service"
    echo -e "  ${BOLD}3)${NC} Save configuration only"
    echo
    
    read -rp "Your choice [1-3]: " choice
    
    save_config
    
    case "$choice" in
        1)
            echo
            print_success "Configuration saved. Starting rotation..."
            sleep 2
            return 0
            ;;
        2)
            install_systemd_service
            echo
            print_success "Service installed and started!"
            echo -e "\nUseful commands:"
            echo -e "  Check status:  ${BOLD}systemctl status mullvad-rotator${NC}"
            echo -e "  View logs:     ${BOLD}journalctl -u mullvad-rotator -f${NC}"
            echo -e "  Stop service:  ${BOLD}systemctl stop mullvad-rotator${NC}"
            echo
            exit 0
            ;;
        3)
            echo
            print_success "Configuration saved!"
            echo -e "\nTo start rotation manually, run:"
            echo -e "  ${BOLD}sudo $0${NC}"
            echo
            exit 0
            ;;
    esac
}

install_systemd_service() {
    local service_file="/etc/systemd/system/mullvad-rotator.service"
    local script_path
    script_path=$(readlink -f "$0")
    
    cat > "$service_file" << EOF
[Unit]
Description=Mullvad VPN Server Rotator
After=network-online.target mullvad-daemon.service
Wants=network-online.target
Requires=mullvad-daemon.service

[Service]
Type=simple
ExecStart=$script_path
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable mullvad-rotator.service
    systemctl start mullvad-rotator.service
    
    print_success "Systemd service installed and started"
}

run_setup_wizard() {
    wizard_welcome
    wizard_check_requirements
    
    while true; do
        wizard_country_selection
        wizard_rotation_interval
        wizard_logging
        wizard_advanced
        
        if wizard_summary; then
            break
        fi
        
        echo -e "\nLet's reconfigure...\n"
        sleep 1
    done
    
    wizard_save_and_install
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN ROTATION LOOP
# ═══════════════════════════════════════════════════════════════════════════════

show_status() {
    local status location ip
    status=$(mullvad_get_status)
    location=$(mullvad_get_location)
    ip=$(mullvad_get_ip)
    
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  Status:   ${BOLD}${status}${NC}"
    echo -e "${CYAN}│${NC}  Location: ${BOLD}${location}${NC}"
    echo -e "${CYAN}│${NC}  IP:       ${BOLD}${ip}${NC}"
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
}

rotation_loop() {
    log "Starting Mullvad server rotation"
    log "Country: $COUNTRY_CODE | Interval: ${RECONNECT_INTERVAL}s | Protocol: $TUNNEL_PROTOCOL"
    
    # Set tunnel protocol
    mullvad_set_protocol "$TUNNEL_PROTOCOL"
    
    RETRY_COUNT=0
    BACKOFF_DELAY=$INITIAL_BACKOFF
    
    while $RUNNING; do
        local current_status current_country
        current_status=$(mullvad_get_status)
        current_country=$(mullvad_get_country_code)
        
        # For specific country: skip rotation if already connected correctly
        if [[ "$COUNTRY_CODE" != "any" ]]; then
            if [[ "$current_status" == "connected" && "$current_country" == "$COUNTRY_CODE" ]]; then
                log "Connected to $COUNTRY_CODE. Next rotation in ${RECONNECT_INTERVAL}s."
                sleep "$RECONNECT_INTERVAL" || true
                RETRY_COUNT=0
                BACKOFF_DELAY=$INITIAL_BACKOFF
                continue
            fi
        else
            # For "any": wait interval if already connected, then rotate
            if [[ "$current_status" == "connected" ]]; then
                log "Connected to $current_country. Rotating in ${RECONNECT_INTERVAL}s."
                sleep "$RECONNECT_INTERVAL" || true
            fi
        fi
        
        log "Connecting to new relay (target: $COUNTRY_CODE)..."
        
        if mullvad_reconnect "$COUNTRY_CODE"; then
            local new_country new_location
            new_country=$(mullvad_get_country_code)
            new_location=$(mullvad_get_location)
            
            log "Connected to $new_country ($new_location)"
            
            RETRY_COUNT=0
            BACKOFF_DELAY=$INITIAL_BACKOFF
            
            # Only sleep if this is a specific country (for "any", we already slept above)
            if [[ "$COUNTRY_CODE" != "any" ]]; then
                sleep "$RECONNECT_INTERVAL" || true
            fi
        else
            ((RETRY_COUNT++)) || true
            log "Connection failed (attempt $RETRY_COUNT/$MAX_RETRIES)" "ERROR"
            
            if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
                log "Maximum retries exceeded. Exiting." "ERROR"
                cleanup
            fi
            
            log "Retrying in ${BACKOFF_DELAY}s..." "WARN"
            sleep "$BACKOFF_DELAY" || true
            BACKOFF_DELAY=$((BACKOFF_DELAY * BACKOFF_MULTIPLIER))
            
            # Cap backoff at 5 minutes
            [[ $BACKOFF_DELAY -gt 300 ]] && BACKOFF_DELAY=300
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMMAND LINE INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    cat << EOF
${BOLD}Mullvad VPN Server Rotator v${SCRIPT_VERSION}${NC}

${BOLD}USAGE:${NC}
    $0 [OPTIONS]

${BOLD}OPTIONS:${NC}
    --setup, -s         Run interactive setup wizard
    --status            Show current VPN connection status
    --start             Start rotation (using saved config)
    --stop              Stop rotation service
    --config            Show current configuration
    --help, -h          Show this help message
    --version, -v       Show version

${BOLD}EXAMPLES:${NC}
    sudo $0 --setup     Run the setup wizard
    sudo $0             Start with saved configuration
    sudo $0 --status    Check current VPN status

${BOLD}CONFIGURATION FILE:${NC}
    $CONFIG_FILE

EOF
}

show_version() {
    echo "Mullvad VPN Server Rotator v${SCRIPT_VERSION}"
}

show_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${BOLD}Current Configuration:${NC}\n"
        cat "$CONFIG_FILE"
    else
        print_warning "No configuration file found."
        echo "Run '$0 --setup' to create one."
    fi
}

show_current_status() {
    require_cmd mullvad
    print_header
    show_status
}

stop_service() {
    if systemctl is-active mullvad-rotator &>/dev/null; then
        systemctl stop mullvad-rotator
        print_success "Rotation service stopped"
    else
        print_info "Service is not running"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup|-s)
                SETUP_MODE=true
                shift
                ;;
            --status)
                show_current_status
                exit 0
                ;;
            --config)
                show_config
                exit 0
                ;;
            --stop)
                require_root
                stop_service
                exit 0
                ;;
            --start)
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                show_version
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
    
    # Root required for main operations
    require_root
    
    # Check dependencies
    require_cmd mullvad mullvad-vpn
    require_cmd flock util-linux
    require_cmd column bsdextrautils
    require_cmd systemctl systemd
    
    # Setup mode
    if [[ "$SETUP_MODE" == true ]]; then
        run_setup_wizard
    fi
    
    # Load configuration
    if ! load_config; then
        print_warning "No configuration found. Starting setup wizard..."
        sleep 2
        run_setup_wizard
    fi
    
    # Validate country code
    if ! mullvad_validate_country "$COUNTRY_CODE"; then
        die "Invalid country code '$COUNTRY_CODE' in configuration."
    fi
    
    # Prepare logging
    if [[ "$LOG_TO_FILE" == true ]]; then
        local log_dir
        log_dir=$(dirname "$LOG_FILE")
        mkdir -p "$log_dir" 2>/dev/null || true
        
        if ! touch "$LOG_FILE" 2>/dev/null; then
            print_warning "Cannot write to $LOG_FILE, using stdout only"
            LOG_TO_FILE=false
        fi
    fi
    
    # Acquire lock
    acquire_lock
    
    # Setup signal handlers
    setup_signals
    
    # Show header and status
    print_header
    show_status
    echo
    
    # Run main loop
    rotation_loop
}

main "$@"