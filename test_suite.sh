#!/usr/bin/env bash

# Mock functions for testing
mullvad() {
    case "$1 $2" in
        "status ")
            echo "$MOCK_STATUS"
            ;;
        "relay list")
            echo "$MOCK_RELAY_LIST"
            ;;
        *)
            return 0
            ;;
    esac
}

# Functions to test (copied from Debian.sh)
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
    local location
    location=$(echo "$status" | grep -oP 'in \K[^,^.]+, [^,^.]+' | head -1) || true
    if [[ -n "$location" ]]; then echo "$location"; else echo "none"; fi
}

mullvad_get_country_code() {
    local status
    status=$(mullvad status 2>/dev/null) || { echo "none"; return; }
    local relay
    relay=$(echo "$status" | grep -oP 'Connected to \K[a-z]{2}' | head -1) || true
    if [[ -n "$relay" ]]; then echo "$relay"; else echo "none"; fi
}

mullvad_get_ip() {
    local status
    status=$(mullvad status 2>/dev/null) || { echo "unknown"; return; }
    local ip
    ip=$(echo "$status" | grep -oP 'IPv4: \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; else echo "unknown"; fi
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
    if echo "$countries" | grep -qx "$country"; then return 0; fi
    return 1
}

# Test Runner
test_parsing() {
    echo "--- Testing Parsing Logic on WSL ---"
    
    # Test 1: Connected status
    MOCK_STATUS="Connected to se-got-wg-001 in Gothenburg, Sweden. IPv4: 193.138.218.71"
    [[ $(mullvad_get_status) == "connected" ]] || echo "Fail: get_status (connected)"
    [[ $(mullvad_get_location) == "Gothenburg, Sweden" ]] || echo "Fail: get_location ($(mullvad_get_location))"
    [[ $(mullvad_get_country_code) == "se" ]] || echo "Fail: get_country_code"
    [[ $(mullvad_get_ip) == "193.138.218.71" ]] || echo "Fail: get_ip"
    
    # Test 2: Connecting status
    MOCK_STATUS="Connecting to US server..."
    [[ $(mullvad_get_status) == "connecting" ]] || echo "Fail: get_status (connecting)"
    
    # Test 3: Disconnected status
    MOCK_STATUS="Disconnected"
    [[ $(mullvad_get_status) == "disconnected" ]] || echo "Fail: get_status (disconnected)"
    
    # Test 4: Multiline/Complex location
    MOCK_STATUS="Connected to us-nyc-wg-101 in New York City, United States of America. IPv4: 104.28.14.1"
    [[ $(mullvad_get_location) == "New York City, United States of America" ]] || echo "Fail: get_location complex ($(mullvad_get_location))"
    
    # Test 5: Relay List
    MOCK_RELAY_LIST="se	Sweden
us	United States
de	Germany"
    
    [[ $(mullvad_list_countries | wc -l) -eq 3 ]] || echo "Fail: list_countries count"
    mullvad_validate_country "us" || echo "Fail: validate_country (valid)"
    ! mullvad_validate_country "it" || echo "Fail: validate_country (invalid)"
    
    echo "Tests completed on WSL."
}

test_parsing
