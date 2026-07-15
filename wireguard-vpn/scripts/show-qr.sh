#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Show QR Code Script
# =============================================================================
# Usage     : sudo ./scripts/show-qr.sh <client-name>
# Example   : sudo ./scripts/show-qr.sh alice
# What it does:
#   - Displays the client config as a QR code in the terminal
#   - The user scans this with the WireGuard mobile app
#   - Also shows where the PNG QR code image is saved
#
# SECURITY NOTE: The QR code contains the client's PRIVATE KEY.
#   Only display this on a trusted screen. Clear the terminal after use.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

die()  { echo -e "  ${RED}✖${NC}  $1" >&2; exit 1; }
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || die "server.env not found."
source "$SERVER_ENV"

[[ $EUID -ne 0 ]] && die "Must be run as root."
[[ $# -lt 1 ]]    && die "Usage: sudo $0 <client-name>"

CLIENT_NAME="$1"
CLIENT_DIR="${CLIENT_CONFIG_DIR}/${CLIENT_NAME}"
CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"
QR_FILE="${CLIENT_DIR}/${CLIENT_NAME}-qr.png"

# Validate
[[ -f "$CLIENT_CONF" ]] || die "Client config not found: ${CLIENT_CONF}\nDid you run add-client.sh?"

echo ""
echo -e "  ${BOLD}${BLUE}QR Code for client: ${CLIENT_NAME}${NC}"
echo -e "  ${YELLOW}⚠  This contains a PRIVATE KEY — only show on trusted screens${NC}"
echo ""

# ─── Display QR in terminal ───────────────────────────────────────────────────
# qrencode -t UTF8: Renders the QR code using Unicode block characters
# This works in any modern terminal. The user scans it with their phone.
# -m 2: Add a 2-module margin (white border) so phone cameras can read it
echo -e "  ${BOLD}Scan this QR code with the WireGuard app:${NC}"
echo ""

qrencode -t UTF8 -m 2 < "$CLIENT_CONF"

echo ""

# ─── Also (re)generate the PNG QR code if needed ─────────────────────────────
if [[ ! -f "$QR_FILE" ]]; then
    qrencode -t PNG -o "$QR_FILE" -s 6 -l M < "$CLIENT_CONF"
    chmod 600 "$QR_FILE"
fi

ok "Terminal QR displayed above — scan with WireGuard mobile app"
info "PNG image saved at: ${QR_FILE}"
info "Download PNG: scp root@<server-ip>:${QR_FILE} ."

echo ""
echo -e "  ${BOLD}How to connect on mobile:${NC}"
echo -e "   1. Install the WireGuard app from App Store / Google Play"
echo -e "   2. Tap '+' then 'Scan QR Code'"
echo -e "   3. Point your camera at the QR code above"
echo -e "   4. Name the tunnel (e.g., '${CLIENT_NAME}') and tap 'Create Tunnel'"
echo -e "   5. Tap the toggle to connect"
echo ""
echo -e "  ${BOLD}How to connect on desktop:${NC}"
echo -e "   Linux   : sudo cp ${CLIENT_CONF} /etc/wireguard/wg0.conf"
echo -e "             sudo systemctl enable --now wg-quick@wg0"
echo -e "   Windows : Import ${CLIENT_NAME}.conf in the WireGuard app"
echo -e "   macOS   : Import ${CLIENT_NAME}.conf in the WireGuard app"
echo ""
echo -e "  ${YELLOW}After distributing the config, consider running:${NC}"
echo -e "  ${YELLOW}sudo shred -u ${CLIENT_CONF}  # Securely delete from server${NC}"
echo ""
