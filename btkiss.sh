#!/bin/bash

# Bluetooth KISS TNC Manager
# Single script to manage Bluetooth TNC connections for AX.25

set -e

CONFIG_FILE="/etc/ax25/btkiss.conf"
AXPORTS_FILE="/etc/ax25/axports"

# Default values
RFCOMM_NUM="0"
RFCOMM_DEVICE="/dev/rfcomm0"
AXPORT_NAME="btport"
SKIP_KISS=false
CLI_CALLSIGN=""

# Color codes
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'

# Logging functions
log_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

log_section() {
    local label="$1"
    local message="$2"
    echo -e "${CYAN}[${label}]${NC} ${message}"
}

log_progress() {
    echo -e "       ${1}"
}

log_success() {
    echo -e "       ${GREEN}✓${NC} ${1}"
}

log_error() {
    echo -e "${RED}Error:${NC} ${1}"
}

log_action() {
    echo
    echo -e "${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
    while IFS= read -r line; do
        printf "${YELLOW}│${NC} %-58s ${YELLOW}│${NC}\n" "$line"
    done
    echo -e "${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"
    echo
}

log_separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run with sudo"
        exit 1
    fi
}

# Check prerequisites
check_prereqs() {
    local missing=0
    local os_type=""
    local install_cmd=""

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_type="$ID"
        os_version="$VERSION_ID"
    fi

    # Check for required commands
    for cmd in kissattach kissparms axlisten rfcomm bluetoothctl; do
        if ! command -v $cmd &> /dev/null; then
            missing=1
            break
        fi
    done

    if [ $missing -eq 1 ]; then
        log_error "Missing required tools"
        echo

        if [ "$os_type" = "debian" ]; then
            echo "Install with:"
            echo "  sudo apt update"
            echo "  sudo apt install -y ax25-tools ax25-apps bluetooth"
        else
            echo "Detected OS: $os_type (not fully supported yet)"
            echo "Try installing: ax25-tools ax25-apps bluetooth"
        fi
        exit 1
    fi
}

# List Bluetooth devices
list_devices() {
    log_header "Bluetooth KISS TNC Manager - Device Scanner"

    log_section "SCAN" "Searching for Bluetooth devices..."

    # Start bluetooth if not running
    systemctl start bluetooth 2>/dev/null || true

    # Scan (suppress bluez debug output)
    timeout 10 bluetoothctl --timeout 10 scan on > /dev/null 2>&1 &
    sleep 10

    echo
    log_separator
    bluetoothctl devices 2>/dev/null
    log_separator
    echo

    # Highlight compatible TNC devices if found
    compatible=$(bluetoothctl devices 2>/dev/null | grep -iE "UV-PRO|RT-660|VR-N76|VR-N7600" || true)
    if [ -n "$compatible" ]; then
        log_section "FOUND" "Compatible TNC devices:"
        while IFS= read -r line; do
            mac=$(echo "$line" | awk '{print $2}')
            name=$(echo "$line" | awk '{print $3}')
            log_success "${CYAN}${name}${NC} (${mac})"
            log_progress "Connect: ${WHITE}sudo $(basename $0) --connect $mac${NC}"
        done <<< "$compatible"
        echo
    fi

    echo -e "${YELLOW}Note:${NC} If your device doesn't show up:"
    echo "  1. Enable 'Pairing' mode in device settings"
    echo "  2. Rerun: sudo $(basename $0) --list-devices"
    echo
}

# Load config
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi
}

# Save config
save_config() {
    local mac="$1"
    local callsign="$2"

    mkdir -p /etc/ax25
    cat > "$CONFIG_FILE" << EOF
DEVICE_MAC="$mac"
CALLSIGN="$callsign"
EOF
}

# Clean Bluetooth cache of known TNC devices
cleanup_bluetooth_cache() {
    log_section "CLEANUP" "Cleaning Bluetooth cache..."

    cached_devices=$(bluetoothctl devices 2>/dev/null | grep -iE "UV-PRO|RT-660|VR-N76|VR-N7600" || true)

    if [ -n "$cached_devices" ]; then
        while IFS= read -r device; do
            mac=$(echo "$device" | awk '{print $2}')
            log_progress "Removing cached device: $mac"
            bluetoothctl disconnect $mac >/dev/null 2>&1 || true
            bluetoothctl untrust $mac >/dev/null 2>&1 || true
            bluetoothctl remove $mac >/dev/null 2>&1 || true
        done <<< "$cached_devices"
        log_success "Cache cleaned"
    else
        log_success "No cached devices to clean"
    fi
    echo
}

# Auto-connect to first found device
do_auto_connect() {
    log_header "Bluetooth KISS TNC Manager - Auto Connect"

    systemctl start bluetooth 2>/dev/null

    # Clean cache FIRST
    cleanup_bluetooth_cache

    log_section "SCAN" "Searching for compatible devices..."
    timeout 10 bluetoothctl --timeout 10 scan on > /dev/null 2>&1 &
    sleep 10

    devices=$(bluetoothctl devices 2>/dev/null)
    compatible_devices=$(echo "$devices" | grep -iE "UV-PRO|RT-660|VR-N76|VR-N7600" || true)

    if [ -z "$compatible_devices" ]; then
        log_error "No compatible devices found"
        echo
        echo "Make sure your device is:"
        echo "  - Powered ON"
        echo "  - Bluetooth enabled"
        echo "  - Pairing is turned on (Menu > Pairing > Press OK)"
        exit 1
    fi

    # Get first device
    first_device=$(echo "$compatible_devices" | head -1)
    mac=$(echo "$first_device" | awk '{print $2}')
    name=$(echo "$first_device" | awk '{print $3}')

    device_count=$(echo "$compatible_devices" | wc -l)
    if [ "$device_count" -gt 1 ]; then
        log_success "Found $device_count devices, using: ${CYAN}${name}${NC} (${mac})"
    else
        log_success "Found: ${CYAN}${name}${NC} (${mac})"
    fi
    echo

    # Connect to it (skip_cleanup=true since we just cleaned)
    do_connect "$mac" true
}

# Setup/Connect
do_connect() {
    local mac="$1"
    local skip_bluetooth_cleanup="${2:-false}"

    if [ -z "$mac" ]; then
        log_error "MAC address required"
        echo "Usage: sudo $(basename $0) --connect <MAC_ADDRESS>"
        echo "Or use: sudo $(basename $0) --auto-connect"
        exit 1
    fi

    # Only show header if not called from auto-connect
    if [ "$skip_bluetooth_cleanup" = "false" ]; then
        log_header "Bluetooth KISS TNC Manager"
    fi

    DEVICE_MAC="$mac"

    # Cleanup old connections FIRST, before anything else
    log_section "SETUP" "Preparing connection..."
    # Only kill processes for this specific RFCOMM device, not other TNCs
    pkill -f "kissattach ${RFCOMM_DEVICE}" 2>/dev/null || true
    pkill -f "rfcomm connect ${RFCOMM_DEVICE}" 2>/dev/null || true
    sleep 2
    rfcomm release ${RFCOMM_DEVICE} 2>/dev/null || true
    sleep 1
    log_success "Old connections cleaned up"

    load_config

    # Check if we need to setup callsign
    if [ -z "$CALLSIGN" ]; then
        # Use CLI callsign if provided, otherwise prompt
        if [ -n "$CLI_CALLSIGN" ]; then
            CALLSIGN="$CLI_CALLSIGN"
        else
            echo
            read -p "Callsign (e.g., N0CALL-1): " CALLSIGN

            if [ -z "$CALLSIGN" ]; then
                log_error "Callsign required"
                exit 1
            fi
        fi

        # Save config
        save_config "$DEVICE_MAC" "$CALLSIGN"

        # Configure axports
        mkdir -p /etc/ax25
        cat > "$AXPORTS_FILE" << EOF
# name    callsign        speed  paclen  window  description
${AXPORT_NAME}    $CALLSIGN       1200   255     2       Bluetooth TNC
EOF

        log_success "Configuration saved"
        echo
    fi

    # Check if device is paired
    bt_info=$(bluetoothctl info $DEVICE_MAC 2>/dev/null || echo "")

    if [ -z "$bt_info" ] || ! echo "$bt_info" | grep -q "Paired: yes"; then
        echo
        log_section "PAIR" "Device needs pairing"
        echo
        echo "⚠  ACTION REQUIRED - On your UV-PRO radio:

   1. Menu > Pairing
   2. Press OK to activate pairing mode
   3. Wait for pairing mode indicator

Press ENTER only after pressing OK on radio..." | log_action
        read -p ""
        echo

        # Start scan
        log_progress "Scanning..."
        timeout 30 bluetoothctl --timeout 30 scan on > /dev/null 2>&1 &
        SCAN_PID=$!

        # Wait for device to be discovered
        log_progress "Waiting for device to be discovered..."
        device_found=0
        for i in {1..15}; do
            if bluetoothctl devices 2>/dev/null | grep -q "$DEVICE_MAC"; then
                log_success "Device discovered"
                device_found=1
                break
            fi
            sleep 1
        done

        if [ $device_found -eq 0 ]; then
            kill $SCAN_PID 2>/dev/null || true
            log_error "Device not discovered"
            echo "Make sure device is in pairing mode"
            exit 1
        fi

        # Clean slate - remove any old pairing data (skip if already cleaned)
        if [ "$skip_bluetooth_cleanup" != "true" ]; then
            log_progress "Cleaning old pairing data..."
            bluetoothctl disconnect $DEVICE_MAC >/dev/null 2>&1 || true
            bluetoothctl untrust $DEVICE_MAC >/dev/null 2>&1 || true
            bluetoothctl remove $DEVICE_MAC >/dev/null 2>&1 || true
            sleep 2

            # Verify device is still visible after removal
            log_progress "Re-checking device visibility..."
            for i in {1..10}; do
                if bluetoothctl devices 2>/dev/null | grep -q "$DEVICE_MAC"; then
                    log_success "Device visible"
                    break
                fi
                sleep 1
            done
        fi

        # Trust THEN pair (order matters!)
        log_progress "Trusting device..."
        trust_result=$(bluetoothctl trust $DEVICE_MAC 2>&1 || true)
        if echo "$trust_result" | grep -q "not available"; then
            kill $SCAN_PID 2>/dev/null || true
            log_error "Device not available for trust"
            echo "Turn device off/on and retry"
            exit 1
        fi

        if ! echo "$trust_result" | grep -q "trust succeeded"; then
            kill $SCAN_PID 2>/dev/null || true
            log_error "Trust failed"
            echo "$trust_result"
            exit 1
        fi
        log_success "Trusted"

        log_progress "Pairing..."
        pair_result=$(bluetoothctl pair $DEVICE_MAC 2>&1 || true)

        # Stop scan
        kill $SCAN_PID 2>/dev/null || true

        if ! echo "$pair_result" | grep -q "Pairing successful"; then
            log_error "Pairing failed"
            echo "$pair_result" | grep -E "Failed|Error|Canceled"
            echo

            if echo "$pair_result" | grep -q "AuthenticationFailed"; then
                echo "${YELLOW}Authentication Failed means:${NC}"
                echo "  → You didn't press OK in Menu > Pairing on the radio"
                echo
                echo "Fix:"
                echo "  1. Turn radio OFF then ON"
                echo "  2. Menu > Pairing > Press OK"
                echo "  3. Run script again"
            else
                echo "Turn device off, then on, then Menu > Pairing and retry"
            fi
            exit 1
        fi

        log_success "Paired"
        sleep 2
    else
        log_success "Device already paired"
    fi

    # Connect via RFCOMM with retry logic
    echo
    log_section "CONNECT" "Establishing RFCOMM connection..."
    rfcomm_connected=0
    for attempt in {1..3}; do
        log_progress "Attempt $attempt/3..."
        rfcomm_output=$(rfcomm connect ${RFCOMM_DEVICE} $DEVICE_MAC 2>&1) &
        RFCOMM_PID=$!

        # Wait up to 10 seconds for device to appear
        for i in {1..10}; do
            sleep 1
            if [ -e ${RFCOMM_DEVICE} ]; then
                log_success "RFCOMM connected: ${CYAN}${RFCOMM_DEVICE}${NC}"
                rfcomm_connected=1
                break 2
            fi
        done

        # Check for specific errors
        if ps -p $RFCOMM_PID > /dev/null 2>&1; then
            kill $RFCOMM_PID 2>/dev/null || true
        fi

        # Check last rfcomm error in dmesg or logs
        rfcomm_error=$(dmesg | tail -5 | grep -i "rfcomm" 2>/dev/null || echo "")

        if echo "$rfcomm_error" | grep -qi "connection refused"; then
            echo
            log_error "Connection refused - radio needs restart"
            echo
            echo "Fix:"
            echo "  1. Turn radio OFF then ON"
            echo "  2. Menu > Pairing > Press OK"
            echo "  3. Run script again"
            exit 1
        fi

        # Failed this attempt, cleanup and retry
        if [ $rfcomm_connected -eq 0 ]; then
            log_progress "Connection attempt $attempt failed, retrying..."
            sleep 2
        fi
    done

    if [ $rfcomm_connected -eq 0 ]; then
        echo
        log_error "RFCOMM connection failed after 3 attempts"
        echo
        echo "Make sure KISS TNC is enabled on device:"
        echo "  Menu > General Settings > KISS TNC > Enable"
        echo
        echo "If connection keeps failing:"
        echo "  1. Turn radio OFF then ON"
        echo "  2. Run script again"
        exit 1
    fi

    # Attach KISS (if not skipped)
    if [ "$SKIP_KISS" = false ]; then
        echo
        log_section "KISS" "Attaching AX.25 interface..."
        kissattach ${RFCOMM_DEVICE} ${AXPORT_NAME}
        kissparms -c 1 -p ${AXPORT_NAME}

        # Verify
        ax_iface="ax${RFCOMM_NUM}"
        if ip link show ${ax_iface} > /dev/null 2>&1; then
            log_success "Interface created: ${CYAN}${ax_iface}${NC}"
            echo
            log_header "✓ SUCCESS - AX.25 interface ready"
            echo -e "  Interface:  ${CYAN}${ax_iface}${NC}"
            echo -e "  Callsign:   ${WHITE}$CALLSIGN${NC}"
            echo -e "  Device:     ${CYAN}$DEVICE_MAC${NC}"
            log_separator
            echo -e "  Test with:  ${WHITE}sudo axlisten -a -c -t${NC}"
            log_separator
            echo
        else
            log_error "Failed to create ${ax_iface} interface"
            exit 1
        fi
    else
        echo
        log_header "✓ SUCCESS - RFCOMM connected"
        echo -e "  Device:     ${CYAN}${RFCOMM_DEVICE}${NC}"
        echo -e "  MAC:        ${CYAN}$DEVICE_MAC${NC}"
        log_separator
        echo -e "  ${YELLOW}Note:${NC} KISS attach was skipped (--no-kiss)"
        log_separator
        echo
    fi
}

# Halt/Disconnect
do_halt() {
    log_header "Bluetooth KISS TNC Manager - Halt"

    log_section "HALT" "Stopping AX.25 on ${RFCOMM_DEVICE}..."
    # Only kill processes for this specific RFCOMM device, not other TNCs
    pkill -f "kissattach ${RFCOMM_DEVICE}" 2>/dev/null || true
    pkill -f "rfcomm connect ${RFCOMM_DEVICE}" 2>/dev/null || true
    sleep 2
    rfcomm release ${RFCOMM_DEVICE} 2>/dev/null || true
    log_success "Stopped"
    echo
}

# Show usage
usage() {
    log_header "Bluetooth KISS TNC Manager"

    echo "Manage Bluetooth TNC connections for AX.25 packet radio."
    echo
    echo -e "${CYAN}Compatible Devices:${NC}"
    echo "  - BTECH UV-PRO"
    echo "  - Radtel RT-660 (same hardware as UV-PRO)"
    echo "  - VGC VR-N76 (same hardware as UV-PRO)"
    echo "  - VERO VR-N7600 (possibly compatible, untested)"
    echo
    log_separator
    echo -e "${CYAN}Usage:${NC}"
    echo "  sudo $(basename $0) COMMAND [OPTIONS]"
    echo
    echo -e "${CYAN}Commands:${NC}"
    echo "  --connect <MAC>  Connect to Bluetooth TNC and start AX.25"
    echo "  --auto-connect   Scan and connect to first compatible device found"
    echo "  --halt           Stop AX.25 and disconnect"
    echo "  --list-devices   Scan and list Bluetooth devices"
    echo "  --help           Show this help"
    echo
    echo -e "${CYAN}Options:${NC}"
    echo "  --callsign <CALL>   Specify callsign (e.g., N0CALL-1)"
    echo "  --rfcomm <NUM>      Use /dev/rfcommNUM (default: 0)"
    echo "  --no-kiss           Skip KISS attach (Bluetooth/RFCOMM only)"
    echo
    log_separator
    echo -e "${CYAN}Examples:${NC}"
    echo "  sudo $(basename $0) --list-devices"
    echo "  sudo $(basename $0) --auto-connect"
    echo "  sudo $(basename $0) --auto-connect --callsign VA3SYS-1"
    echo "  sudo $(basename $0) --connect 38:D2:00:01:11:FE"
    echo "  sudo $(basename $0) --connect 38:D2:00:01:11:FE --callsign N0CALL-1"
    echo "  sudo $(basename $0) --connect 38:D2:00:01:11:FE --rfcomm 1"
    echo "  sudo $(basename $0) --connect 38:D2:00:01:11:FE --no-kiss"
    echo "  sudo $(basename $0) --halt"
    echo "  sudo $(basename $0) --halt --rfcomm 1"
    echo
    log_separator
    echo -e "${YELLOW}Multiple TNCs:${NC}"
    echo "  Use --rfcomm to specify different devices (0, 1, 2, etc.)"
    echo "  Each RFCOMM device creates its own ax interface (ax0, ax1, ax2, etc.)"
    echo
    echo -e "${YELLOW}First time connecting:${NC}"
    echo "  - Will ask for callsign (unless --callsign provided)"
    echo "  - Pairs with device and saves config to $CONFIG_FILE"
    log_separator
    echo
}

# Parse arguments
COMMAND=""
MAC_ADDRESS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --connect|--auto-connect|--halt|--list-devices|--help)
            COMMAND="$1"
            shift
            # Get MAC address if it's --connect and next arg doesn't start with --
            if [ "$COMMAND" = "--connect" ] && [ $# -gt 0 ] && [[ ! "$1" =~ ^-- ]]; then
                MAC_ADDRESS="$1"
                shift
            fi
            ;;
        --callsign)
            CLI_CALLSIGN="$2"
            shift 2
            ;;
        --rfcomm)
            RFCOMM_NUM="$2"
            RFCOMM_DEVICE="/dev/rfcomm${2}"
            AXPORT_NAME="btport${2}"
            shift 2
            ;;
        --no-kiss)
            SKIP_KISS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Execute command
case "$COMMAND" in
    --connect)
        check_root
        check_prereqs
        do_connect "$MAC_ADDRESS"
        ;;
    --auto-connect)
        check_root
        check_prereqs
        do_auto_connect
        ;;
    --halt)
        check_root
        do_halt
        ;;
    --list-devices)
        check_root
        check_prereqs
        list_devices
        ;;
    --help|*)
        usage
        [ "$COMMAND" = "--help" ] && exit 0 || exit 0
        ;;
esac
