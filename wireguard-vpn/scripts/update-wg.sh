#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Update Script
# =============================================================================
# Usage     : sudo ./scripts/update-wg.sh
# What it does:
#   1. Updates all system packages (including WireGuard)
#   2. Checks if a reboot is required
#   3. Optionally restarts WireGuard to load new version
#   4. Verifies WireGuard is still running after update
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

[[ $EUID -ne 0 ]] && die "Must be run as root."

section "WireGuard VPN Update"

# Backup before updating
info "Creating pre-update backup..."
BACKUP_FILE="/root/wg-pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
tar czf "$BACKUP_FILE" -C / etc/wireguard 2>/dev/null && \
    ok "Backup created: ${BACKUP_FILE}"

# Update package lists
info "Updating package index..."
apt-get update -qq

# Show available WireGuard upgrade
WG_UPDATE=$(apt-get -s upgrade 2>/dev/null | grep wireguard || echo "")
if [[ -n "$WG_UPDATE" ]]; then
    echo -e "  ${YELLOW}WireGuard update available:${NC}"
    echo "$WG_UPDATE" | sed 's/^/    /'
else
    info "WireGuard is already up to date"
fi

# Upgrade all packages
info "Upgrading packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

ok "Packages updated"

# Clean up old package versions
apt-get autoremove -y > /dev/null 2>&1
apt-get autoclean > /dev/null 2>&1
ok "Package cache cleaned"

# Check if reboot is needed
if [[ -f /var/run/reboot-required ]]; then
    warn "A system REBOOT is required to apply kernel updates."
    warn "Schedule a reboot at a convenient time: sudo reboot"
    warn "WireGuard will restart automatically after reboot."
fi

# Restart WireGuard if it was already running
SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] && source "$SERVER_ENV" || WG_INTERFACE="wg0"

if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    info "Restarting WireGuard to load updated binaries..."
    systemctl restart "wg-quick@${WG_INTERFACE}"

    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        ok "WireGuard restarted successfully"
    else
        die "WireGuard failed to restart! Restore from backup: ${BACKUP_FILE}"
    fi
fi

# Show current WireGuard version
WG_VERSION=$(wg --version 2>/dev/null || echo "unknown")
info "WireGuard version: ${WG_VERSION}"

section "Update Complete"
echo ""
ok "System and WireGuard updated successfully"
echo ""
