#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Uninstall Script
# =============================================================================
# Run as    : sudo ./uninstall.sh
# What it does:
#   1. Stops and disables the WireGuard service
#   2. Removes UFW rules added by the installer
#   3. Removes WireGuard configuration files (with optional backup)
#   4. Uninstalls WireGuard packages
#   5. Reverts sysctl IP forwarding settings
#   6. Removes Fail2Ban custom config
#   7. Removes management scripts from /usr/local/bin
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

WG_INTERFACE="wg0"
WG_CONFIG_DIR="/etc/wireguard"
WG_PORT="51820"
WG_SUBNET="10.100.0.0/24"

# =============================================================================
# PRE-FLIGHT
# =============================================================================
[[ $EUID -ne 0 ]] && die "Must be run as root: sudo ./uninstall.sh"

echo ""
echo -e "${RED}${BOLD}  ⚠  WireGuard VPN UNINSTALLER${NC}"
echo ""
echo -e "  This will ${RED}COMPLETELY REMOVE${NC} WireGuard VPN from this server."
echo -e "  All client configurations and keys will be ${RED}DELETED${NC}."
echo ""
read -rp "  Are you SURE you want to proceed? Type 'yes' to confirm: " confirm
[[ "$confirm" == "yes" ]] || { echo "  Aborted."; exit 0; }

# =============================================================================
# STEP 1 — Optional backup before deletion
# =============================================================================
section "Optional Backup"

read -rp "  Create a backup of all configs before removing? [Y/n] " do_backup
if [[ "${do_backup,,}" != "n" ]]; then
    BACKUP_FILE="/root/wireguard-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    # tar czf: Create a compressed (gzip) archive
    # -C /: Change to root directory so paths are absolute inside archive
    tar czf "$BACKUP_FILE" -C / etc/wireguard 2>/dev/null || true
    ok "Backup saved to: ${BACKUP_FILE}"
fi

# =============================================================================
# STEP 2 — Stop WireGuard service
# =============================================================================
section "Stopping WireGuard"

# wg-quick down: Removes the wg0 interface and runs PostDown commands
# This also removes the iptables NAT rules added by PostUp
if ip link show "${WG_INTERFACE}" > /dev/null 2>&1; then
    info "Bringing down WireGuard interface ${WG_INTERFACE}..."
    wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
    ok "Interface ${WG_INTERFACE} down"
fi

# systemctl stop: Stops the running service
# systemctl disable: Removes the autostart symlink so it won't start on boot
systemctl stop "wg-quick@${WG_INTERFACE}"  2>/dev/null || true
systemctl disable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
ok "WireGuard service stopped and disabled"

# =============================================================================
# STEP 3 — Remove UFW rules
# =============================================================================
section "Removing Firewall Rules"

# Remove specific UFW rules by port number
info "Removing WireGuard UFW rules..."
ufw delete allow "${WG_PORT}/udp" > /dev/null 2>&1 || true

# Remove the NAT rules we added to /etc/ufw/before.rules
info "Removing NAT rules from UFW before.rules..."
if [[ -f /etc/ufw/before.rules ]]; then
    # Remove the block of lines we inserted (from the comment to the COMMIT line)
    sed -i '/# WireGuard NAT rules/,/^$/d' /etc/ufw/before.rules 2>/dev/null || true
fi

# Revert DEFAULT_FORWARD_POLICY to DROP for security
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw

ufw reload > /dev/null 2>&1 || true
ok "Firewall rules removed"

# =============================================================================
# STEP 4 — Remove sysctl settings
# =============================================================================
section "Reverting Kernel Settings"

# Remove the sysctl file we created
rm -f /etc/sysctl.d/99-wireguard.conf

# Revert IP forwarding in the running kernel
sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=0 > /dev/null 2>&1 || true

ok "IP forwarding disabled"

# =============================================================================
# STEP 5 — Remove configuration files
# =============================================================================
section "Removing Configuration Files"

info "Removing /etc/wireguard..."
rm -rf "${WG_CONFIG_DIR}"
ok "WireGuard config directory removed"

# =============================================================================
# STEP 6 — Uninstall packages
# =============================================================================
section "Uninstalling Packages"

read -rp "  Remove WireGuard packages? [Y/n] " remove_pkgs
if [[ "${remove_pkgs,,}" != "n" ]]; then
    # apt-get remove: Removes packages but keeps config files
    # apt-get purge: Removes packages AND their configuration files
    # --autoremove: Also removes unused dependencies
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        wireguard \
        wireguard-tools \
        2>/dev/null || true

    apt-get autoremove -y 2>/dev/null || true
    ok "WireGuard packages removed"
fi

read -rp "  Remove qrencode? [y/N] " remove_qr
if [[ "${remove_qr,,}" == "y" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y qrencode 2>/dev/null || true
    ok "qrencode removed"
fi

# =============================================================================
# STEP 7 — Remove Fail2Ban custom config
# =============================================================================
section "Removing Fail2Ban Config"

rm -f /etc/fail2ban/jail.local
systemctl restart fail2ban 2>/dev/null || true
ok "Fail2Ban custom config removed"

# =============================================================================
# STEP 8 — Remove management scripts
# =============================================================================
section "Removing Management Scripts"

rm -f /usr/local/bin/wgvpn-*
ok "Management scripts removed from /usr/local/bin"

# =============================================================================
# STEP 9 — Remove automatic updates config (optional)
# =============================================================================
read -rp "  Remove automatic security updates config? [y/N] " remove_updates
if [[ "${remove_updates,,}" == "y" ]]; then
    rm -f /etc/apt/apt.conf.d/50unattended-upgrades
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
    ok "Auto-updates config removed"
fi

# =============================================================================
# Done
# =============================================================================
section "Uninstall Complete"

echo ""
echo -e "  ${GREEN}WireGuard VPN has been fully removed.${NC}"
if [[ "${do_backup,,}" != "n" ]] && [[ -f "${BACKUP_FILE:-}" ]]; then
    echo -e "  ${CYAN}Your backup is at: ${BACKUP_FILE}${NC}"
fi
echo ""
