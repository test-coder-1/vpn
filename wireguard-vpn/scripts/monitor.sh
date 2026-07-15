#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Live Monitoring Script
# =============================================================================
# Usage     : sudo ./scripts/monitor.sh
# Options   :
#   --once   Print status once and exit (good for cron)
#   --watch  Continuous live refresh (default)
#
# What it shows:
#   - WireGuard interface status
#   - All connected/idle peers with transfer stats
#   - Server network statistics
#   - System resource usage
#   - Recent log entries
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Must be run as root."; exit 1; }

SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] && source "$SERVER_ENV" || WG_INTERFACE="wg0"

ONCE=false
[[ "${1:-}" == "--once" ]] && ONCE=true

# ─── Format bytes into human-readable ────────────────────────────────────────
format_bytes() {
    local bytes=${1:-0}
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=2; $bytes/1073741824" | bc)GB"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=1; $bytes/1048576" | bc)MB"
    elif (( bytes >= 1024 )); then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

# ─── Format seconds as relative time ─────────────────────────────────────────
format_age() {
    local age=${1:-0}
    if (( age < 60 )); then
        echo "${age}s ago"
    elif (( age < 3600 )); then
        echo "$(( age/60 ))m $(( age%60 ))s ago"
    elif (( age < 86400 )); then
        echo "$(( age/3600 ))h $(( (age%3600)/60 ))m ago"
    else
        echo "$(( age/86400 ))d $(( (age%86400)/3600 ))h ago"
    fi
}

# ─── Main display function ────────────────────────────────────────────────────
show_status() {
    clear

    echo ""
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║        WireGuard VPN Monitor — $(date '+%Y-%m-%d %H:%M:%S')        ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Interface status ──────────────────────────────────────────────────────
    echo -e "${BOLD}  Interface: ${WG_INTERFACE}${NC}"

    if ! ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
        echo -e "  ${RED}✖  WireGuard is DOWN${NC}"
        echo -e "     Start with: sudo systemctl start wg-quick@${WG_INTERFACE}"
        return
    fi

    echo -e "  ${GREEN}✔  WireGuard is UP${NC}"

    # Get interface details
    # ip addr show: Shows IP addresses assigned to the interface
    IFACE_IP=$(ip addr show "${WG_INTERFACE}" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
    LISTEN_PORT=$(wg show "${WG_INTERFACE}" listen-port 2>/dev/null || echo "unknown")
    PUBLIC_KEY=$(wg show "${WG_INTERFACE}" public-key 2>/dev/null || echo "unknown")

    echo -e "  VPN IP    : ${CYAN}${IFACE_IP:-unknown}${NC}"
    echo -e "  Port      : ${CYAN}${LISTEN_PORT}/UDP${NC}"
    echo -e "  Public Key: ${CYAN}${PUBLIC_KEY:0:20}...${NC}"
    echo ""

    # ── Peer stats ────────────────────────────────────────────────────────────
    echo -e "${BOLD}  Connected Peers:${NC}"
    echo ""
    printf "  ${BOLD}%-20s %-18s %-20s %-12s %s${NC}\n" \
        "PUBLIC KEY" "ENDPOINT" "LAST HANDSHAKE" "RX" "TX"
    printf "  %-20s %-18s %-20s %-12s %s\n" \
        "────────────────────" "──────────────────" \
        "────────────────────" "────────────" "──────────"

    PEER_COUNT=0
    NOW=$(date +%s)

    # wg show <iface> dump gives tab-separated peer data
    while IFS=$'\t' read -r pub_key psk endpoint allowed_ips hs_ts rx_bytes tx_bytes keepalive; do
        # Skip the interface line (first line of dump)
        [[ "$pub_key" == "$(wg show ${WG_INTERFACE} public-key 2>/dev/null)" ]] && continue

        PEER_COUNT=$(( PEER_COUNT + 1 ))

        # Truncate long public key for display
        SHORT_KEY="${pub_key:0:18}.."

        # Format last handshake
        if [[ "$hs_ts" -gt 0 ]] 2>/dev/null; then
            AGE=$(( NOW - hs_ts ))
            HS_DISPLAY=$(format_age $AGE)

            if (( AGE < 180 )); then
                HS_COLOUR="${GREEN}"
            elif (( AGE < 3600 )); then
                HS_COLOUR="${YELLOW}"
            else
                HS_COLOUR="${RED}"
            fi
        else
            HS_DISPLAY="never"
            HS_COLOUR="${RED}"
        fi

        # Format endpoint
        EP_DISPLAY="${endpoint:-not connected}"
        [[ "$EP_DISPLAY" == "(none)" ]] && EP_DISPLAY="not connected"

        # Truncate endpoint for display
        [[ ${#EP_DISPLAY} -gt 18 ]] && EP_DISPLAY="${EP_DISPLAY:0:16}.."

        printf "  %-20s %-18s ${HS_COLOUR}%-20s${NC} %-12s %s\n" \
            "$SHORT_KEY" \
            "$EP_DISPLAY" \
            "$HS_DISPLAY" \
            "$(format_bytes ${rx_bytes:-0})" \
            "$(format_bytes ${tx_bytes:-0})"

    done < <(wg show "${WG_INTERFACE}" dump 2>/dev/null | tail -n +2)

    if [[ $PEER_COUNT -eq 0 ]]; then
        echo -e "  ${YELLOW}  No peers configured${NC}"
    fi

    echo ""
    echo -e "  Total peers: ${CYAN}${PEER_COUNT}${NC}"

    # ── Server stats ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  Server Resources:${NC}"

    # CPU usage (via /proc/loadavg — load averages: 1m, 5m, 15m)
    read -r load1 load5 load15 _ < /proc/loadavg
    echo -e "  CPU Load  : ${CYAN}${load1} (1m)  ${load5} (5m)  ${load15} (15m)${NC}"

    # Memory usage
    MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    MEM_USED=$(( MEM_TOTAL - MEM_FREE ))
    MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
    echo -e "  Memory    : ${CYAN}$(( MEM_USED/1024 ))MB used / $(( MEM_TOTAL/1024 ))MB total (${MEM_PCT}%)${NC}"

    # Disk usage
    DISK_INFO=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')
    echo -e "  Disk      : ${CYAN}${DISK_INFO}${NC}"

    # Network traffic on VPN interface
    if [[ -f "/sys/class/net/${WG_INTERFACE}/statistics/rx_bytes" ]]; then
        IFACE_RX=$(cat "/sys/class/net/${WG_INTERFACE}/statistics/rx_bytes")
        IFACE_TX=$(cat "/sys/class/net/${WG_INTERFACE}/statistics/tx_bytes")
        echo -e "  VPN Total : ${CYAN}↓$(format_bytes $IFACE_RX) received  ↑$(format_bytes $IFACE_TX) sent${NC}"
    fi

    echo ""

    # ── Recent logs ───────────────────────────────────────────────────────────
    echo -e "${BOLD}  Recent WireGuard Log (last 5 entries):${NC}"
    # journalctl: Queries the systemd journal (log system)
    # -u: Filter by unit name
    # -n 5: Show last 5 entries
    # --no-pager: Don't open in a pager (just print)
    # -o short: Short output format
    journalctl -u "wg-quick@${WG_INTERFACE}" -n 5 --no-pager -o short 2>/dev/null | \
        sed 's/^/    /' || echo "    (no logs)"

    echo ""
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  Press ${BOLD}Ctrl+C${NC} to exit  |  Refresh: every 5 seconds"
    echo ""
}

# =============================================================================
# Main loop
# =============================================================================
if $ONCE; then
    show_status
else
    # Continuous mode — refresh every 5 seconds
    # trap: Catch Ctrl+C (SIGINT) and exit gracefully
    trap 'echo -e "\n  Monitor stopped."; exit 0' INT
    while true; do
        show_status
        sleep 5
    done
fi
