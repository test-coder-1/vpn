#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Add Client Script
# =============================================================================
# Usage     : sudo ./scripts/add-client.sh <client-name>
# Example   : sudo ./scripts/add-client.sh alice
# What it does:
#   1. Validates the client name (alphanumeric + dashes only)
#   2. Generates a client keypair (private + public key)
#   3. Generates a preshared key (extra quantum-resistant layer)
#   4. Assigns the next available VPN IP from the IP counter
#   5. Creates the client config file (.conf)
#   6. Generates a QR code PNG image
#   7. Appends the [Peer] block to the server's wg0.conf
#   8. Hot-reloads WireGuard (without dropping existing connections)
#   9. Updates the client registry
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Colour codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}${BOLD}  $1${NC}"; \
            echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
die()  { echo -e "  ${RED}✖${NC}  $1" >&2; exit 1; }

# =============================================================================
# Load server configuration
# =============================================================================
SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || die "Server config not found at ${SERVER_ENV}. Run install.sh first."

# shellcheck source=/etc/wireguard/server.env
source "$SERVER_ENV"

# =============================================================================
# Validate input
# =============================================================================
[[ $EUID -ne 0 ]] && die "Must be run as root: sudo $0 <name>"
[[ $# -lt 1 ]]    && die "Usage: sudo $0 <client-name>  (e.g., alice)"

CLIENT_NAME="$1"

# Validate client name: only lowercase letters, numbers, hyphens, underscores
# No spaces, no special characters — this becomes a filename
if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Invalid client name. Use only letters, numbers, hyphens, and underscores."
fi

# Check if client already exists in the registry
if grep -q "^${CLIENT_NAME}	" "$CLIENT_REGISTRY" 2>/dev/null; then
    die "Client '${CLIENT_NAME}' already exists. Use remove-client.sh first."
fi

# =============================================================================
# Assign IP address
# =============================================================================
section "Assigning IP Address"

# Read the current counter value (e.g., 2 for the first client)
NEXT_IP_OCTET=$(cat "$IP_COUNTER_FILE")

# Validate the counter is within range (2-254 for /24 subnet)
if (( NEXT_IP_OCTET > 254 )); then
    die "VPN subnet is full! Maximum 253 clients reached."
fi

CLIENT_IP="10.100.0.${NEXT_IP_OCTET}"
CLIENT_IP6="fd00:100::${NEXT_IP_OCTET}"

# Increment the counter for the next client
echo $(( NEXT_IP_OCTET + 1 )) > "$IP_COUNTER_FILE"

ok "Assigned IP: ${CLIENT_IP}/32"
ok "Assigned IPv6: ${CLIENT_IP6}/128"

# =============================================================================
# Generate cryptographic keys
# =============================================================================
section "Generating Cryptographic Keys"

CLIENT_DIR="${CLIENT_CONFIG_DIR}/${CLIENT_NAME}"

# Create per-client directory with restricted permissions
install -d -m 700 "$CLIENT_DIR"

CLIENT_PRIVATE_KEY_FILE="${CLIENT_DIR}/private.key"
CLIENT_PUBLIC_KEY_FILE="${CLIENT_DIR}/public.key"
PRESHARED_KEY_FILE="${CLIENT_DIR}/preshared.key"

# Generate client private key
# wg genkey outputs a random 256-bit Curve25519 private key, Base64-encoded
wg genkey | tee "${CLIENT_PRIVATE_KEY_FILE}" | wg pubkey > "${CLIENT_PUBLIC_KEY_FILE}"

# Generate preshared key
# wg genpsk: Generates a 256-bit symmetric preshared key
# This provides an additional layer of post-quantum security.
# Both server and client must share this secret.
wg genpsk > "${PRESHARED_KEY_FILE}"

# Restrict all key files to root-only
chmod 600 "${CLIENT_PRIVATE_KEY_FILE}" "${CLIENT_PUBLIC_KEY_FILE}" "${PRESHARED_KEY_FILE}"

CLIENT_PRIVATE_KEY=$(cat "${CLIENT_PRIVATE_KEY_FILE}")
CLIENT_PUBLIC_KEY=$(cat "${CLIENT_PUBLIC_KEY_FILE}")
PRESHARED_KEY=$(cat "${PRESHARED_KEY_FILE}")

ok "Client keypair generated"
ok "Preshared key generated"
info "Client public key: ${CLIENT_PUBLIC_KEY}"

# =============================================================================
# Create client configuration file
# =============================================================================
section "Creating Client Configuration"

CLIENT_CONF_FILE="${CLIENT_DIR}/${CLIENT_NAME}.conf"

cat > "${CLIENT_CONF_FILE}" << EOF
# =============================================================================
# WireGuard Client Configuration — ${CLIENT_NAME}
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Server: ${SERVER_PUBLIC_IP}:${WG_PORT}
# VPN IP: ${CLIENT_IP}/32
# =============================================================================
#
# HOW TO USE THIS FILE:
#   Windows/macOS : Import this file in the WireGuard app
#   Linux         : sudo cp ${CLIENT_NAME}.conf /etc/wireguard/wg0.conf
#                   sudo systemctl enable --now wg-quick@wg0
#   Android/iOS   : Scan the QR code generated alongside this file
#
# SECURITY WARNING: This file contains your PRIVATE KEY.
#   - Never share this file with anyone
#   - Never upload to cloud storage or version control
#   - Delete this file from the server after copying to client
# =============================================================================

[Interface]
# Your private key (keep this secret!)
PrivateKey = ${CLIENT_PRIVATE_KEY}

# Your VPN IP addresses
Address = ${CLIENT_IP}/32
Address = ${CLIENT_IP6}/128

# DNS servers — using these prevents DNS leaks
# Your ISP will not see your DNS queries
DNS = ${WG_DNS}

# MTU — must match server
MTU = ${WG_MTU}

# ── Kill Switch ───────────────────────────────────────────────────────────────
# These rules block ALL traffic if the VPN drops (prevents data leaks)
# Remove these lines if you want your device to keep internet access when VPN drops
PostUp   = iptables -I OUTPUT ! -o %i -m mark ! --mark \$(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PostDown = iptables -D OUTPUT ! -o %i -m mark ! --mark \$(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT

[Peer]
# Server's public key
PublicKey = ${SERVER_PUBLIC_KEY}

# Preshared key (extra security layer)
PresharedKey = ${PRESHARED_KEY}

# Server address and port — where to connect
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}

# Route ALL traffic through the VPN (full tunnel)
# For split tunnel, change to: AllowedIPs = 10.100.0.0/24
AllowedIPs = 0.0.0.0/0, ::/0

# Send keepalive every 25 seconds — required for NAT traversal
PersistentKeepalive = ${WG_KEEPALIVE}
EOF

chmod 600 "${CLIENT_CONF_FILE}"
ok "Client config created: ${CLIENT_CONF_FILE}"

# =============================================================================
# Generate QR code
# =============================================================================
section "Generating QR Code"

QR_FILE="${CLIENT_DIR}/${CLIENT_NAME}-qr.png"

# qrencode: Reads text from stdin and generates a QR code image
# -t PNG: Output format (can also be SVG, UTF8 for terminal)
# -o: Output file path
# -s 6: Scale factor (pixel size of each QR module)
# -l M: Error correction level (M = ~15% recovery capability)
qrencode -t PNG -o "${QR_FILE}" -s 6 -l M < "${CLIENT_CONF_FILE}"

chmod 600 "${QR_FILE}"
ok "QR code saved: ${QR_FILE}"
info "To display in terminal: sudo ./scripts/show-qr.sh ${CLIENT_NAME}"

# =============================================================================
# Append peer to server config
# =============================================================================
section "Adding Peer to Server"

# Append the [Peer] block to wg0.conf
# This tells WireGuard about the new client so it can accept their connections.
cat >> "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf" << EOF

# ── Peer: ${CLIENT_NAME} ─────────────────────────────────────────────────────
# Added: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
[Peer]
# Client name: ${CLIENT_NAME}
# VPN IP: ${CLIENT_IP}
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32, ${CLIENT_IP6}/128
EOF

ok "Peer appended to wg0.conf"

# =============================================================================
# Hot-reload WireGuard
# =============================================================================
section "Reloading WireGuard"

# wg addconf: Adds a peer to the RUNNING WireGuard interface WITHOUT restarting.
# This means existing client connections are not interrupted.
# We write a temporary config with just the [Peer] block and add it.
TEMP_PEER_CONF=$(mktemp)
cat > "$TEMP_PEER_CONF" << EOF
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32, ${CLIENT_IP6}/128
EOF

# Check if WireGuard is running before trying to hot-reload
if ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    wg addconf "${WG_INTERFACE}" "$TEMP_PEER_CONF"
    ok "Peer hot-added to running WireGuard (no restart needed)"
else
    warn "WireGuard is not running — peer will be active on next start"
fi

rm -f "$TEMP_PEER_CONF"

# =============================================================================
# Update client registry
# =============================================================================

# Append to the registry file: name <tab> ip <tab> timestamp <tab> status
printf "%s\t%s\t%s\tactive\n" \
    "${CLIENT_NAME}" \
    "${CLIENT_IP}" \
    "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
    >> "$CLIENT_REGISTRY"

ok "Registry updated"

# =============================================================================
# Summary
# =============================================================================
section "Client '${CLIENT_NAME}' Added Successfully!"

echo ""
echo -e "  ${BOLD}Client Details:${NC}"
echo -e "    Name        : ${CYAN}${CLIENT_NAME}${NC}"
echo -e "    VPN IP      : ${CYAN}${CLIENT_IP}/32${NC}"
echo -e "    IPv6        : ${CYAN}${CLIENT_IP6}/128${NC}"
echo -e "    Public Key  : ${CYAN}${CLIENT_PUBLIC_KEY}${NC}"
echo -e "    Config file : ${CYAN}${CLIENT_CONF_FILE}${NC}"
echo -e "    QR code     : ${CYAN}${QR_FILE}${NC}"
echo ""
echo -e "  ${BOLD}How to connect:${NC}"
echo -e "    Mobile (QR) : sudo ./scripts/show-qr.sh ${CLIENT_NAME}"
echo -e "    Download    : scp root@${SERVER_PUBLIC_IP}:${CLIENT_CONF_FILE} ."
echo -e "    Linux       : sudo cp ${CLIENT_CONF_FILE} /etc/wireguard/wg0.conf"
echo -e "                  sudo systemctl enable --now wg-quick@wg0"
echo ""
echo -e "  ${YELLOW}⚠  Security reminder: Delete the config from the server after distributing!${NC}"
echo -e "    ${YELLOW}sudo shred -u ${CLIENT_CONF_FILE}${NC}"
echo ""
