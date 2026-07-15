#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — List Clients Script
# =============================================================================
# Usage: sudo ./scripts/list-clients.sh
# Shows all registered clients with their status, IP, and last handshake.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}${BOLD}  $1${NC}"; \
            echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"; }

SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || { echo "server.env not found."; exit 1; }
source "$SERVER_ENV"

[[ $EUID -ne 0 ]] && { echo "Must be run as root."; exit 1; }

section "WireGuard VPN Clients"

# Get live WireGuard peer status
# 'wg show wg0 dump' outputs tab-separated columns:
#   [Interface line]: private_key public_key listen_port fwmark
#   [Peer lines]    : public_key preshared_key endpoint allowed_ips latest_handshake rx_bytes tx_bytes persistent_keepalive
WG_DUMP=""
if ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    WG_DUMP=$(wg show "${WG_INTERFACE}" dump 2>/dev/null || echo "")
fi

echo ""
printf "  %-15s %-16s %-12s %-20s %s\n" \
    "NAME" "VPN IP" "STATUS" "LAST HANDSHAKE" "RX/TX"
printf "  %-15s %-16s %-12s %-20s %s\n" \
    "───────────────" "────────────────" "────────────" "────────────────────" "──────────"

# Read client registry
FOUND_CLIENTS=0

while IFS=$'\t' read -r name ip created status; do
    # Skip comment lines and empty lines
    [[ "$name" =~ ^#.*$ ]] && continue
    [[ -z "$name" ]] && continue

    FOUND_CLIENTS=$(( FOUND_CLIENTS + 1 ))

    # Get the client's public key to look up in wg dump
    PUBLIC_KEY_FILE="${CLIENT_CONFIG_DIR}/${name}/public.key"
    CLIENT_PUBLIC_KEY=""
    [[ -f "$PUBLIC_KEY_FILE" ]] && CLIENT_PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")

    # Look up live data in wg dump
    LAST_HANDSHAKE="never"
    RX_TX="—"
    LIVE_STATUS="offline"

    if [[ -n "$WG_DUMP" ]] && [[ -n "$CLIENT_PUBLIC_KEY" ]]; then
        # Find the peer's line in the dump output
        PEER_LINE=$(echo "$WG_DUMP" | grep "^${CLIENT_PUBLIC_KEY}" || echo "")

        if [[ -n "$PEER_LINE" ]]; then
            # Column 5 (0-indexed) is latest_handshake (Unix timestamp)
            HS_TIMESTAMP=$(echo "$PEER_LINE" | cut -f5)
            RX_BYTES=$(echo "$PEER_LINE" | cut -f6)
            TX_BYTES=$(echo "$PEER_LINE" | cut -f7)

            if [[ "$HS_TIMESTAMP" -gt 0 ]] 2>/dev/null; then
                # Convert bytes to human-readable
                # A handshake in the last 3 minutes = "connected"
                NOW=$(date +%s)
                AGE=$(( NOW - HS_TIMESTAMP ))

                if (( AGE < 180 )); then
                    LIVE_STATUS="connected"
                    LAST_HANDSHAKE="$(( AGE ))s ago"
                elif (( AGE < 3600 )); then
                    LIVE_STATUS="idle"
                    LAST_HANDSHAKE="$(( AGE / 60 ))m ago"
                elif (( AGE < 86400 )); then
                    LIVE_STATUS="idle"
                    LAST_HANDSHAKE="$(( AGE / 3600 ))h ago"
                else
                    LIVE_STATUS="offline"
                    LAST_HANDSHAKE="$(( AGE / 86400 ))d ago"
                fi

                # Format bytes as KB/MB
                format_bytes() {
                    local bytes=$1
                    if (( bytes > 1048576 )); then
                        echo "$(( bytes / 1048576 ))MB"
                    elif (( bytes > 1024 )); then
                        echo "$(( bytes / 1024 ))KB"
                    else
                        echo "${bytes}B"
                    fi
                }
                RX_TX="↓$(format_bytes $RX_BYTES) ↑$(format_bytes $TX_BYTES)"
            fi
        fi
    fi

    # Colour-code the status
    if [[ "$status" == "revoked" ]]; then
        STATUS_DISPLAY="${RED}revoked${NC}"
        LIVE_STATUS="revoked"
    elif [[ "$LIVE_STATUS" == "connected" ]]; then
        STATUS_DISPLAY="${GREEN}connected${NC}"
    elif [[ "$LIVE_STATUS" == "idle" ]]; then
        STATUS_DISPLAY="${YELLOW}idle${NC}"
    else
        STATUS_DISPLAY="${RED}offline${NC}"
    fi

    # Print the row
    printf "  %-15s %-16s " "$name" "$ip"
    printf "${STATUS_DISPLAY}"
    # Pad status field (colours add invisible chars, so manually pad)
    printf "%-$(( 12 - ${#LIVE_STATUS} ))s" ""
    printf " %-20s %s\n" "$LAST_HANDSHAKE" "$RX_TX"

done < "$CLIENT_REGISTRY"

if [[ $FOUND_CLIENTS -eq 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}No clients registered yet.${NC}"
    echo -e "  Add a client with: ${CYAN}sudo ./scripts/add-client.sh <name>${NC}"
fi

echo ""
echo -e "  Total clients: ${CYAN}${FOUND_CLIENTS}${NC}"

# Show overall WireGuard interface status
echo ""
section "Interface Status"

if ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✔${NC}  WireGuard interface ${BOLD}${WG_INTERFACE}${NC} is UP"
    echo ""
    # wg show: Displays the current configuration and status of WireGuard
    wg show "${WG_INTERFACE}" 2>/dev/null || true
else
    echo -e "  ${RED}✖${NC}  WireGuard interface ${WG_INTERFACE} is DOWN"
    echo -e "    Start with: ${CYAN}sudo systemctl start wg-quick@${WG_INTERFACE}${NC}"
fi

echo ""
