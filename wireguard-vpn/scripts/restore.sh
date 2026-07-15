#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Restore Script
# =============================================================================
# Usage: sudo ./scripts/restore.sh /path/to/wg-backup-YYYYMMDD-HHMMSS.tar.gz
# What it does:
#   - Validates the backup file (checksum if available)
#   - Stops WireGuard
#   - Restores /etc/wireguard from the archive
#   - Fixes permissions
#   - Restarts WireGuard
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
[[ $# -lt 1 ]]    && die "Usage: sudo $0 /path/to/backup.tar.gz"

BACKUP_FILE="$1"

# Decrypt if .enc file
if [[ "$BACKUP_FILE" == *.enc ]]; then
    section "Decrypting Backup"
    DECRYPTED="${BACKUP_FILE%.enc}"
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
        -in "$BACKUP_FILE" -out "$DECRYPTED"
    BACKUP_FILE="$DECRYPTED"
    ok "Backup decrypted"
fi

[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: ${BACKUP_FILE}"

section "Restoring WireGuard Configuration"

# Verify checksum if available
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
    info "Verifying checksum..."
    sha256sum -c "$CHECKSUM_FILE" && ok "Checksum verified" || die "Checksum FAILED — backup may be corrupted!"
else
    warn "No checksum file found — proceeding without verification"
fi

# Stop WireGuard
info "Stopping WireGuard..."
systemctl stop "wg-quick@wg0" 2>/dev/null || true

# Backup current config before overwriting
CURRENT_BACKUP="/root/wg-pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
tar czf "$CURRENT_BACKUP" -C / etc/wireguard 2>/dev/null || true
info "Current config backed up to: ${CURRENT_BACKUP}"

# Clear and restore
rm -rf /etc/wireguard
tar xzpf "$BACKUP_FILE" -C /

# Fix permissions (in case they were altered)
chmod 700 /etc/wireguard
chmod 600 /etc/wireguard/*.conf 2>/dev/null || true
chmod 600 /etc/wireguard/*.key  2>/dev/null || true
chmod 600 /etc/wireguard/server.env 2>/dev/null || true
chmod 700 /etc/wireguard/clients 2>/dev/null || true

ok "Files restored and permissions fixed"

# Restart WireGuard
info "Restarting WireGuard..."
systemctl start "wg-quick@wg0"

if systemctl is-active --quiet "wg-quick@wg0"; then
    ok "WireGuard restarted successfully"
else
    die "WireGuard failed to start after restore. Check: journalctl -u wg-quick@wg0"
fi

section "Restore Complete"
echo ""
echo -e "  ${GREEN}Configuration restored from: ${BACKUP_FILE}${NC}"
echo -e "  Verify with: ${CYAN}sudo wg show${NC}"
echo ""
