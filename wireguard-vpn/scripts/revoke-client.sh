#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Revoke Client Script
# =============================================================================
# Usage     : sudo ./scripts/revoke-client.sh <client-name>
# Example   : sudo ./scripts/revoke-client.sh alice
#
# DIFFERENCE from remove-client.sh:
#   revoke = Block access immediately. Keys and config PRESERVED.
#            The client record is kept with status=revoked.
#            Can be reviewed/audited later. Cannot be re-enabled
#            without manually editing the registry and wg0.conf.
#   remove = Complete permanent deletion of all traces.
#
# USE revoke when:
#   - A device is lost/stolen (block immediately)
#   - You want to keep an audit trail
#   - You may want to re-examine the client record
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

SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || die "server.env not found."
source "$SERVER_ENV"

[[ $EUID -ne 0 ]] && die "Must be run as root."
[[ $# -lt 1 ]]    && die "Usage: sudo $0 <client-name>"

CLIENT_NAME="$1"
CLIENT_DIR="${CLIENT_CONFIG_DIR}/${CLIENT_NAME}"

# =============================================================================
# Validate
# =============================================================================
section "Revoking Client: ${CLIENT_NAME}"

if ! grep -q "^${CLIENT_NAME}	" "$CLIENT_REGISTRY" 2>/dev/null; then
    die "Client '${CLIENT_NAME}' not found in registry."
fi

# Check if already revoked
if grep -q "^${CLIENT_NAME}	.*	revoked$" "$CLIENT_REGISTRY" 2>/dev/null; then
    warn "Client '${CLIENT_NAME}' is already revoked."
    exit 0
fi

# Get public key for live removal
CLIENT_PUBLIC_KEY=""
[[ -f "${CLIENT_DIR}/public.key" ]] && CLIENT_PUBLIC_KEY=$(cat "${CLIENT_DIR}/public.key")

echo ""
echo -e "  ${YELLOW}This will immediately block access for: ${BOLD}${CLIENT_NAME}${NC}"
echo -e "  Keys and config files will be PRESERVED."
echo ""
read -rp "  Confirm revocation? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "  Aborted."; exit 0; }

# =============================================================================
# Step 1 — Remove peer from LIVE WireGuard (immediate effect)
# =============================================================================
section "Blocking Peer (Live)"

if [[ -n "$CLIENT_PUBLIC_KEY" ]] && ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    # This immediately disconnects the client and prevents reconnection
    # until the server is restarted (since wg0.conf still has the peer,
    # the peer would reconnect on restart — hence we also edit wg0.conf below)
    wg set "${WG_INTERFACE}" peer "${CLIENT_PUBLIC_KEY}" remove 2>/dev/null && \
        ok "Peer removed from live WireGuard instance" || \
        warn "Could not remove live peer"
else
    warn "Skipping live removal (WireGuard not running or key not found)"
fi

# =============================================================================
# Step 2 — Comment out peer in wg0.conf (persistent block)
# =============================================================================
section "Updating wg0.conf (Persistent Block)"

WG_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

# Use Python to comment out the [Peer] block for this client.
# We add a "REVOKED" comment so the block is clearly marked.
python3 - "${WG_CONF}" "${CLIENT_NAME}" "${CLIENT_PUBLIC_KEY}" << 'PYEOF'
import sys, re

conf_file  = sys.argv[1]
client_name = sys.argv[2]
client_pubkey = sys.argv[3] if len(sys.argv) > 3 else ""

with open(conf_file, 'r') as f:
    content = f.read()

# Find the peer block and prepend each line with # (comment it out)
# Pattern: from the peer comment header to the next peer header or EOF
pattern = r'(\n# ─+ Peer: ' + re.escape(client_name) + r' ─+.*?)(?=\n# ─+|\Z)'

def comment_out(match):
    block = match.group(1)
    lines = block.split('\n')
    # Add REVOKED notice at the start of the block
    commented = ['\n# ⚠ REVOKED — ' + client_name + ' — access blocked']
    for line in lines:
        if line.strip():
            commented.append('# ' + line if not line.startswith('#') else line)
        else:
            commented.append(line)
    return '\n'.join(commented)

new_content = re.sub(pattern, comment_out, content, flags=re.DOTALL)

with open(conf_file, 'w') as f:
    f.write(new_content)

print(f"  Peer block for '{client_name}' commented out in wg0.conf")
PYEOF

ok "Peer disabled in wg0.conf"

# =============================================================================
# Step 3 — Update registry status
# =============================================================================
section "Updating Registry"

# Change status from 'active' to 'revoked' in the registry
# We also add a revocation timestamp
TEMP_REG=$(mktemp)
while IFS=$'\t' read -r name ip created status; do
    if [[ "$name" == "$CLIENT_NAME" ]]; then
        printf "%s\t%s\t%s\trevoked\t%s\n" \
            "$name" "$ip" "$created" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    else
        printf "%s\t%s\t%s\t%s\n" "$name" "$ip" "$created" "$status"
    fi
done < "$CLIENT_REGISTRY" > "$TEMP_REG"

mv "$TEMP_REG" "$CLIENT_REGISTRY"
chmod 600 "$CLIENT_REGISTRY"

ok "Registry updated — ${CLIENT_NAME} marked as revoked"

# =============================================================================
# Step 4 — Rename client config to indicate revocation
# =============================================================================
if [[ -f "${CLIENT_DIR}/${CLIENT_NAME}.conf" ]]; then
    mv "${CLIENT_DIR}/${CLIENT_NAME}.conf" \
       "${CLIENT_DIR}/${CLIENT_NAME}.conf.revoked"
    ok "Client config renamed to .revoked"
fi

# =============================================================================
# Done
# =============================================================================
section "Revocation Complete"

echo ""
echo -e "  ${RED}✔${NC}  Client '${CLIENT_NAME}' has been REVOKED."
echo -e ""
echo -e "  ${BOLD}What happened:${NC}"
echo -e "   • Client was disconnected from the live VPN immediately"
echo -e "   • Peer block in wg0.conf was commented out (won't reconnect on restart)"
echo -e "   • Registry shows status: revoked"
echo -e "   • Keys preserved at: ${CYAN}${CLIENT_DIR}${NC}"
echo -e ""
echo -e "  ${BOLD}To permanently delete:${NC}"
echo -e "   ${CYAN}sudo ./scripts/remove-client.sh ${CLIENT_NAME}${NC}"
echo ""
