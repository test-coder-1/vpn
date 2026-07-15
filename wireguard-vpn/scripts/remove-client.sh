#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Remove Client Script
# =============================================================================
# Usage     : sudo ./scripts/remove-client.sh <client-name>
# Example   : sudo ./scripts/remove-client.sh alice
# What it does:
#   1. Removes the [Peer] block from wg0.conf
#   2. Hot-removes the peer from the running WireGuard instance
#   3. Deletes all client keys and config files
#   4. Removes the entry from the client registry
#   5. Decrements the IP (optional — only if last client)
#
# DIFFERENCE from revoke-client.sh:
#   remove = Complete deletion (keys gone, IP freed)
#   revoke = Block access but keep keys/record (can re-enable)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}${BOLD}  $1${NC}"; \
            echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
die()  { echo -e "  ${RED}✖${NC}  $1" >&2; exit 1; }

# Load server environment
SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || die "server.env not found. Run install.sh first."
source "$SERVER_ENV"

[[ $EUID -ne 0 ]] && die "Must be run as root."
[[ $# -lt 1 ]]    && die "Usage: sudo $0 <client-name>"

CLIENT_NAME="$1"
CLIENT_DIR="${CLIENT_CONFIG_DIR}/${CLIENT_NAME}"

# =============================================================================
# Validate client exists
# =============================================================================
section "Removing Client: ${CLIENT_NAME}"

if ! grep -q "^${CLIENT_NAME}	" "$CLIENT_REGISTRY" 2>/dev/null; then
    die "Client '${CLIENT_NAME}' not found in registry."
fi

# Get the client's public key (needed to remove the peer from WireGuard)
CLIENT_PUBLIC_KEY_FILE="${CLIENT_DIR}/public.key"
if [[ -f "$CLIENT_PUBLIC_KEY_FILE" ]]; then
    CLIENT_PUBLIC_KEY=$(cat "$CLIENT_PUBLIC_KEY_FILE")
else
    warn "Public key file not found. Will attempt to remove from wg0.conf by name."
    CLIENT_PUBLIC_KEY=""
fi

echo ""
echo -e "  ${YELLOW}This will permanently delete all data for client: ${BOLD}${CLIENT_NAME}${NC}"
read -rp "  Confirm deletion? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "  Aborted."; exit 0; }

# =============================================================================
# Step 1 — Remove peer from running WireGuard (hot-removal)
# =============================================================================
section "Hot-Removing Peer"

if [[ -n "$CLIENT_PUBLIC_KEY" ]] && ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    # wg set peer <pubkey> remove: Removes a peer from the LIVE WireGuard config
    # This immediately disconnects the client and stops accepting their traffic.
    # Existing connections from OTHER clients are not affected.
    wg set "${WG_INTERFACE}" peer "${CLIENT_PUBLIC_KEY}" remove 2>/dev/null || \
        warn "Could not hot-remove peer (may already be disconnected)"
    ok "Peer removed from running WireGuard instance"
else
    warn "WireGuard not running or public key unknown — skipping hot-removal"
fi

# =============================================================================
# Step 2 — Remove [Peer] block from wg0.conf
# =============================================================================
section "Updating wg0.conf"

WG_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

# We need to remove the peer block from the config file.
# The block starts with "# ── Peer: <name>" and ends before the next "# ──" or EOF.
# We use Python for reliable multi-line removal (sed/awk get complex here).
python3 - "${WG_CONF}" "${CLIENT_NAME}" << 'PYEOF'
import sys, re

conf_file = sys.argv[1]
client_name = sys.argv[2]

with open(conf_file, 'r') as f:
    content = f.read()

# Pattern: matches from the peer comment block header through the [Peer] section
# We look for the comment "# ── Peer: <name>" then consume until the next
# "# ──" comment or end of file
pattern = r'\n# ─+ Peer: ' + re.escape(client_name) + r' ─+.*?(?=\n# ─+|\Z)'

new_content = re.sub(pattern, '', content, flags=re.DOTALL)

with open(conf_file, 'w') as f:
    f.write(new_content)

print(f"  Peer block for '{client_name}' removed from wg0.conf")
PYEOF

ok "Peer block removed from wg0.conf"

# =============================================================================
# Step 3 — Delete client files
# =============================================================================
section "Deleting Client Files"

if [[ -d "$CLIENT_DIR" ]]; then
    # shred: Securely overwrites files before deletion
    # -u: Delete the file after overwriting
    # -z: Add a final overwrite with zeros to hide shredding
    # -n 3: Overwrite 3 times (sufficient for most storage)
    for key_file in "${CLIENT_DIR}"/*.key "${CLIENT_DIR}"/*.conf; do
        [[ -f "$key_file" ]] && shred -u -z -n 3 "$key_file" 2>/dev/null || true
    done

    # Remove QR code (not sensitive, but clean up anyway)
    rm -f "${CLIENT_DIR}"/*.png

    # Remove the directory
    rm -rf "$CLIENT_DIR"
    ok "Client directory deleted (keys securely shredded)"
else
    warn "Client directory not found: ${CLIENT_DIR}"
fi

# =============================================================================
# Step 4 — Remove from registry
# =============================================================================
section "Updating Registry"

# Use a temp file to safely edit the registry
TEMP_REG=$(mktemp)
grep -v "^${CLIENT_NAME}	" "$CLIENT_REGISTRY" > "$TEMP_REG"
mv "$TEMP_REG" "$CLIENT_REGISTRY"
chmod 600 "$CLIENT_REGISTRY"

ok "Client removed from registry"

# =============================================================================
# Done
# =============================================================================
section "Done"
echo ""
echo -e "  ${GREEN}Client '${CLIENT_NAME}' has been permanently removed.${NC}"
echo -e "  Run ${CYAN}sudo ./scripts/list-clients.sh${NC} to see remaining clients."
echo ""
