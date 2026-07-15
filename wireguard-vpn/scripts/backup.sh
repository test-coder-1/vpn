#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Backup Script
# =============================================================================
# Usage     : sudo ./scripts/backup.sh [output-directory]
# Default   : Saves backup to /root/wg-backups/
# What it does:
#   - Archives /etc/wireguard/ (all configs, keys, client configs)
#   - Encrypts the archive with AES-256 using a password (optional)
#   - Timestamps the backup file
#   - Prints a checksum for verification
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

SERVER_ENV="/etc/wireguard/server.env"
[[ -f "$SERVER_ENV" ]] || die "server.env not found."
source "$SERVER_ENV"

# Output directory — default to /root/wg-backups/
BACKUP_BASE="${1:-/root/wg-backups}"
mkdir -p "$BACKUP_BASE"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="wg-backup-${TIMESTAMP}"
BACKUP_FILE="${BACKUP_BASE}/${BACKUP_NAME}.tar.gz"

section "WireGuard Configuration Backup"

# =============================================================================
# Create the archive
# =============================================================================

info "Creating archive: ${BACKUP_FILE}"

# tar options explained:
#   c = create a new archive
#   z = compress with gzip
#   f = archive filename follows
#   p = preserve permissions (important for 600 files)
#   --exclude = skip these patterns
tar czpf "$BACKUP_FILE" \
    --exclude='*.revoked' \
    -C / \
    etc/wireguard

ok "Archive created"

# =============================================================================
# Generate SHA256 checksum
# =============================================================================

CHECKSUM_FILE="${BACKUP_FILE}.sha256"
# sha256sum: Generates a cryptographic hash to verify file integrity
sha256sum "$BACKUP_FILE" > "$CHECKSUM_FILE"
CHECKSUM=$(cat "$CHECKSUM_FILE" | awk '{print $1}')

# Restrict backup files to root-only
chmod 600 "$BACKUP_FILE" "$CHECKSUM_FILE"

ok "Checksum: ${CHECKSUM}"

# =============================================================================
# Optional encryption
# =============================================================================

read -rp "  Encrypt backup with password? [y/N] " encrypt_backup
if [[ "${encrypt_backup,,}" == "y" ]]; then
    ENCRYPTED_FILE="${BACKUP_FILE}.enc"

    # openssl enc: Encrypt using AES-256-CBC
    # -aes-256-cbc: Strong symmetric encryption
    # -pbkdf2: Use PBKDF2 key derivation (more secure than default)
    # -iter 100000: 100k iterations — makes brute-force much slower
    # -salt: Add random salt to prevent rainbow table attacks
    echo -e "  ${YELLOW}Enter encryption password (write it down — you NEED it to restore):${NC}"
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
        -in "$BACKUP_FILE" -out "$ENCRYPTED_FILE"

    # Remove unencrypted backup
    shred -u -z "$BACKUP_FILE"
    BACKUP_FILE="$ENCRYPTED_FILE"

    ok "Backup encrypted: ${BACKUP_FILE}"
    warn "IMPORTANT: Keep the password safe — you need it to restore!"
fi

# =============================================================================
# Cleanup old backups (keep last 5)
# =============================================================================

BACKUP_COUNT=$(ls "${BACKUP_BASE}"/wg-backup-*.tar.gz* 2>/dev/null | wc -l)
if (( BACKUP_COUNT > 5 )); then
    info "Removing old backups (keeping last 5)..."
    ls -t "${BACKUP_BASE}"/wg-backup-*.tar.gz* | tail -n +6 | xargs rm -f
    ok "Old backups cleaned up"
fi

# =============================================================================
# Summary
# =============================================================================
section "Backup Complete"

echo ""
echo -e "  ${BOLD}Backup file  :${NC} ${CYAN}${BACKUP_FILE}${NC}"
echo -e "  ${BOLD}Checksum     :${NC} ${CYAN}${CHECKSUM}${NC}"
echo -e "  ${BOLD}Size         :${NC} $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""
echo -e "  ${BOLD}To restore:${NC}"
echo -e "   ${CYAN}sudo ./scripts/restore.sh ${BACKUP_FILE}${NC}"
echo ""
echo -e "  ${YELLOW}⚠  Copy this backup to a SECURE location off this server!${NC}"
echo -e "  ${YELLOW}   scp root@<server>:${BACKUP_FILE} ./wg-backup.tar.gz${NC}"
echo ""
