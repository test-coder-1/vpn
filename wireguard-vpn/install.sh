#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN — Full Server Installation Script
# =============================================================================
# Target OS : Ubuntu Server 24.04 LTS
# Run as    : sudo ./install.sh
# What it does:
#   1. Validates system requirements
#   2. Installs WireGuard, qrencode, fail2ban, and dependencies
#   3. Enables IPv4 and IPv6 forwarding in the kernel
#   4. Generates server public/private keypair
#   5. Creates /etc/wireguard/wg0.conf from template
#   6. Configures UFW firewall rules
#   7. Enables and starts the wg-quick@wg0 systemd service
#   8. Configures Fail2Ban for SSH protection
#   9. Sets up unattended security upgrades
#  10. Initialises the client registry and IP counter
#  11. Saves server.env for use by management scripts
# =============================================================================

set -euo pipefail   # Exit on error, undefined var, or pipe failure
IFS=$'\n\t'         # Safer word splitting

# ─── Colour codes for pretty output ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ─── Helper functions ─────────────────────────────────────────────────────────

# Print a section header
section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}${BOLD}  $1${NC}"; \
            echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"; }

# Print a success message
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }

# Print an informational message
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

# Print a warning
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

# Print an error and exit
die()  { echo -e "  ${RED}✖${NC}  $1" >&2; exit 1; }

# ─── VPN Configuration ───────────────────────────────────────────────────────
# Modify these values before running if you want different settings.

WG_INTERFACE="wg0"
WG_PORT="51820"
WG_SUBNET="10.100.0.0/24"
WG_SERVER_IP="10.100.0.1"
WG_DNS="1.1.1.1,8.8.8.8"
WG_MTU="1420"
WG_KEEPALIVE="25"
WG_CONFIG_DIR="/etc/wireguard"
CLIENT_CONFIG_DIR="/etc/wireguard/clients"
IP_COUNTER_FILE="/etc/wireguard/.ip_counter"
CLIENT_REGISTRY="/etc/wireguard/.client_registry"
SERVER_ENV_FILE="/etc/wireguard/server.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# STEP 1 — Pre-flight checks
# =============================================================================
section "Pre-flight Checks"

# Must run as root
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root. Use: sudo ./install.sh"
fi

ok "Running as root"

# Check Ubuntu version
if ! grep -q "Ubuntu 24" /etc/os-release 2>/dev/null; then
    warn "This script is optimised for Ubuntu 24.04. Your OS may differ."
    read -rp "  Continue anyway? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || die "Aborted."
else
    ok "Ubuntu 24.04 detected"
fi

# Check if WireGuard is already installed
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    warn "WireGuard is already running on interface ${WG_INTERFACE}."
    read -rp "  Re-run installation? This will overwrite existing config! [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || die "Aborted."
fi

# Detect the server's primary outbound network interface
# This is the interface that routes traffic to the internet (e.g., eth0, ens3)
# 'ip route get 1.1.1.1' asks: "Which interface would I use to reach 1.1.1.1?"
SERVER_IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+' | head -1)

if [[ -z "$SERVER_IFACE" ]]; then
    die "Cannot detect primary network interface. Set SERVER_IFACE manually."
fi

ok "Primary interface: ${SERVER_IFACE}"

# Detect the server's public IPv4 address
# We query Cloudflare's IP echo service
SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                  curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
                  ip route get 1.1.1.1 | grep -oP 'src \K\S+' | head -1)

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    read -rp "  Cannot auto-detect public IP. Enter it manually: " SERVER_PUBLIC_IP
fi

ok "Public IP: ${SERVER_PUBLIC_IP}"

# =============================================================================
# STEP 2 — Install packages
# =============================================================================
section "Installing Packages"

# Update package index
# apt-get update: Refreshes the list of available packages from repositories
info "Updating package index..."
apt-get update -qq

# Install required packages:
#   wireguard        — the VPN software (kernel module + userspace tools)
#   wireguard-tools  — wg, wg-quick CLI tools
#   qrencode         — generates QR codes from text (for mobile clients)
#   fail2ban         — bans IPs with too many failed auth attempts
#   ufw              — Uncomplicated Firewall (manages iptables rules)
#   curl             — HTTP client (used above and in scripts)
#   git              — version control (useful for updates)
#   unattended-upgrades — automatic security updates
#   resolvconf       — DNS resolver configuration manager
info "Installing WireGuard and dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard \
    wireguard-tools \
    qrencode \
    fail2ban \
    ufw \
    curl \
    git \
    unattended-upgrades \
    apt-listchanges \
    resolvconf \
    iptables \
    iptables-persistent \
    2>/dev/null

ok "All packages installed"

# =============================================================================
# STEP 3 — Enable IP forwarding
# =============================================================================
section "Enabling IP Forwarding"

# IP forwarding allows the Linux kernel to act as a ROUTER.
# Without this, the server will DROP packets coming from VPN clients
# that are destined for the internet — the VPN would be useless.
#
# We must enable it for BOTH IPv4 and IPv6.
# We write to /etc/sysctl.d/ so the setting survives reboots.

cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
# ── IPv4 forwarding ──────────────────────────────────────────────────────────
# Allow the kernel to forward packets between network interfaces.
# Required for VPN routing (clients → internet via server).
net.ipv4.ip_forward = 1

# ── IPv6 forwarding ──────────────────────────────────────────────────────────
net.ipv6.conf.all.forwarding = 1

# ── Reverse path filtering ───────────────────────────────────────────────────
# Loose mode (2) — required for WireGuard's asymmetric routing.
# Strict mode (1) blocks packets that don't arrive on the "expected" interface,
# which breaks WireGuard tunnels. Use loose mode.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# ── TCP hardening ────────────────────────────────────────────────────────────
# Protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1
# Don't accept ICMP redirects (prevents MITM attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# Don't send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
# Ignore ping broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Log packets with impossible addresses
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

# Apply the settings immediately (without rebooting)
# sysctl -p: Load settings from the specified file
sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null 2>&1

ok "IPv4 forwarding enabled"
ok "IPv6 forwarding enabled"
ok "TCP hardening applied"

# =============================================================================
# STEP 4 — Generate server keys
# =============================================================================
section "Generating Server Cryptographic Keys"

# Create the WireGuard config directory with restricted permissions
# 700 = only root (owner) can read, write, and enter this directory
install -d -m 700 "${WG_CONFIG_DIR}"
install -d -m 700 "${CLIENT_CONFIG_DIR}"

SERVER_PRIVATE_KEY_FILE="${WG_CONFIG_DIR}/server_private.key"
SERVER_PUBLIC_KEY_FILE="${WG_CONFIG_DIR}/server_public.key"

# Generate keys only if they don't already exist
if [[ ! -f "$SERVER_PRIVATE_KEY_FILE" ]]; then
    # wg genkey: Generates a random 256-bit private key (Base64-encoded)
    # This uses the kernel's random number generator — cryptographically secure.
    wg genkey | tee "${SERVER_PRIVATE_KEY_FILE}" | \
        # wg pubkey: Derives the public key from the private key using Curve25519
        wg pubkey > "${SERVER_PUBLIC_KEY_FILE}"

    # Restrict private key to root-only read
    chmod 600 "${SERVER_PRIVATE_KEY_FILE}"
    chmod 644 "${SERVER_PUBLIC_KEY_FILE}"
    ok "Server keypair generated"
else
    ok "Server keypair already exists — reusing"
fi

SERVER_PRIVATE_KEY=$(cat "${SERVER_PRIVATE_KEY_FILE}")
SERVER_PUBLIC_KEY=$(cat "${SERVER_PUBLIC_KEY_FILE}")

info "Public key: ${SERVER_PUBLIC_KEY}"

# =============================================================================
# STEP 5 — Generate wg0.conf
# =============================================================================
section "Creating WireGuard Server Configuration"

# Build the server config from our template by substituting variables.
# sed: Stream editor — replace {{PLACEHOLDER}} with actual values.

cat > "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf" << EOF
# =============================================================================
# WireGuard Server Configuration — Auto-generated by install.sh
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# DO NOT EDIT MANUALLY unless you know what you are doing.
# =============================================================================

[Interface]
# Server private key (Curve25519)
PrivateKey = ${SERVER_PRIVATE_KEY}

# Server VPN IP addresses (IPv4 and IPv6)
Address = ${WG_SERVER_IP}/24
Address = fd00:100::1/64

# Listen for incoming WireGuard connections on this UDP port
ListenPort = ${WG_PORT}

# MTU — set slightly below Ethernet MTU (1500) to account for WireGuard overhead
MTU = ${WG_MTU}

# ── NAT and forwarding rules (applied when the interface comes up) ─────────────
# These commands enable packet forwarding and masquerading so VPN clients
# can route their traffic through this server and reach the internet.
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${SERVER_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -s fd00:100::/64 -o ${SERVER_IFACE} -j MASQUERADE
PostUp = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp = ip6tables -A FORWARD -o %i -j ACCEPT

# ── Cleanup rules (applied when the interface is brought down) ─────────────────
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${SERVER_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s fd00:100::/64 -o ${SERVER_IFACE} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT
PostDown = ip6tables -D FORWARD -o %i -j ACCEPT

# ── [Peer] blocks are appended below by add-client.sh ─────────────────────────
EOF

# Restrict the config file to root-only (contains private key!)
chmod 600 "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

ok "wg0.conf created at ${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

# =============================================================================
# STEP 6 — Initialise client registry
# =============================================================================
section "Initialising Client Registry"

# IP counter: tracks the next available last-octet for client IPs.
# We start at 2 (server is .1, clients start at .2)
if [[ ! -f "$IP_COUNTER_FILE" ]]; then
    echo "2" > "$IP_COUNTER_FILE"
    chmod 600 "$IP_COUNTER_FILE"
    ok "IP counter initialised (next client: 10.100.0.2)"
fi

# Client registry: a tab-separated file storing client name, IP, and creation date.
if [[ ! -f "$CLIENT_REGISTRY" ]]; then
    echo "# name	ip	created	status" > "$CLIENT_REGISTRY"
    chmod 600 "$CLIENT_REGISTRY"
    ok "Client registry created at ${CLIENT_REGISTRY}"
fi

# =============================================================================
# STEP 7 — Configure UFW Firewall
# =============================================================================
section "Configuring UFW Firewall"

# UFW (Uncomplicated Firewall) is a wrapper around iptables.
# We need to:
#   1. Allow SSH (so we don't lock ourselves out!)
#   2. Allow WireGuard UDP port
#   3. Allow forwarded packets (VPN traffic)
#   4. Enable the firewall

# UFW needs to allow forwarded packets. Edit the UFW defaults file.
# DEFAULT_FORWARD_POLICY="ACCEPT" tells UFW to forward packets between interfaces.
info "Configuring UFW forward policy..."
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# Add NAT rules BEFORE the UFW rules in /etc/ufw/before.rules
# We insert our MASQUERADE rule after the *nat table header.
# This is the same NAT rule as in wg0.conf PostUp, but managed by UFW.
info "Adding NAT rules to UFW..."

# Check if we already added these rules to avoid duplicates
if ! grep -q "WireGuard NAT" /etc/ufw/before.rules 2>/dev/null; then
    # Prepend NAT rules at the top of before.rules (before *filter table)
    sed -i "1s/^/# WireGuard NAT rules — added by install.sh\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s ${WG_SUBNET} -o ${SERVER_IFACE} -j MASQUERADE\nCOMMIT\n\n/" \
        /etc/ufw/before.rules
fi

# Allow SSH — CRITICAL: do this BEFORE enabling UFW or you'll be locked out!
# ufw allow: Opens a port
# 22/tcp: SSH port over TCP protocol
info "Allowing SSH (port 22)..."
ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1

# Allow WireGuard port
# 51820/udp: WireGuard uses UDP, not TCP
info "Allowing WireGuard (port ${WG_PORT}/UDP)..."
ufw allow "${WG_PORT}/udp" comment 'WireGuard VPN' > /dev/null 2>&1

# Allow HTTP/HTTPS (optional but useful if server also runs web services)
ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1

# Enable UFW (--force skips the "are you sure?" prompt)
info "Enabling UFW..."
ufw --force enable > /dev/null 2>&1
ufw reload > /dev/null 2>&1

ok "UFW firewall configured and enabled"
ufw status numbered 2>/dev/null | head -20 || true

# =============================================================================
# STEP 8 — Configure Fail2Ban
# =============================================================================
section "Configuring Fail2Ban"

# Fail2Ban monitors log files and bans IPs that show malicious behavior.
# It works by adding temporary iptables DROP rules for offending IPs.

# Create a custom jail configuration
# /etc/fail2ban/jail.local overrides the default /etc/fail2ban/jail.conf
cat > /etc/fail2ban/jail.local << 'EOF'
# =============================================================================
# Fail2Ban jail configuration — WireGuard VPN server
# =============================================================================

[DEFAULT]
# Ban duration in seconds (3600 = 1 hour)
bantime  = 3600
# Time window for counting failures (600 = 10 minutes)
findtime  = 600
# Number of failures before ban
maxretry = 5
# Which backend to use for log monitoring (systemd = use journald)
backend = systemd
# Send email alerts (configure destemail to enable)
# destemail = admin@example.com
# action = %(action_mwl)s

# ── SSH Protection ────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200

# ── Aggressive SSH Protection ─────────────────────────────────────────────────
# Longer bans for repeat offenders
[sshd-aggressive]
enabled  = true
port     = ssh
filter   = sshd[mode=aggressive]
logpath  = /var/log/auth.log
maxretry = 2
bantime  = 86400

# ── UFW ban action ────────────────────────────────────────────────────────────
[ufw]
enabled = true
filter  = ufw
logpath = /var/log/ufw.log
maxretry = 10
bantime  = 3600
EOF

# Enable and restart Fail2Ban
systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1

ok "Fail2Ban configured and started"

# =============================================================================
# STEP 9 — Enable automatic security updates
# =============================================================================
section "Configuring Automatic Security Updates"

# unattended-upgrades automatically installs security updates.
# This is critical for a VPN server exposed to the internet.

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Automatically upgrade packages from these repositories:
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Automatically reboot if required (at 3am)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Remove unused dependencies automatically
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Write log to /var/log/unattended-upgrades/
Unattended-Upgrade::Mail "";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

ok "Automatic security updates enabled"

# =============================================================================
# STEP 10 — Start WireGuard
# =============================================================================
section "Starting WireGuard Service"

# wg-quick is a helper script that reads wg0.conf and:
#   1. Creates the wg0 network interface
#   2. Sets IP addresses
#   3. Sets up routing
#   4. Loads the WireGuard configuration
#   5. Runs PostUp commands

# systemctl enable: Makes the service start automatically on boot
# The service name is wg-quick@wg0 (the '@' means it's parameterised by interface name)
systemctl enable "wg-quick@${WG_INTERFACE}" > /dev/null 2>&1
ok "WireGuard service enabled for auto-start on boot"

# systemctl start: Starts the service right now
systemctl start "wg-quick@${WG_INTERFACE}"
ok "WireGuard service started"

# Verify it's running
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    ok "WireGuard is running!"
else
    die "WireGuard failed to start. Check: journalctl -xeu wg-quick@${WG_INTERFACE}"
fi

# =============================================================================
# STEP 11 — Save server.env for management scripts
# =============================================================================
section "Saving Server Configuration"

cat > "${SERVER_ENV_FILE}" << EOF
# =============================================================================
# WireGuard VPN Server Environment — Auto-generated by install.sh
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Source this file in management scripts: source /etc/wireguard/server.env
# =============================================================================

WG_INTERFACE="${WG_INTERFACE}"
WG_PORT="${WG_PORT}"
WG_SUBNET="${WG_SUBNET}"
WG_SERVER_IP="${WG_SERVER_IP}"
WG_DNS="${WG_DNS}"
WG_MTU="${WG_MTU}"
WG_KEEPALIVE="${WG_KEEPALIVE}"
WG_CONFIG_DIR="${WG_CONFIG_DIR}"
CLIENT_CONFIG_DIR="${CLIENT_CONFIG_DIR}"
IP_COUNTER_FILE="${IP_COUNTER_FILE}"
CLIENT_REGISTRY="${CLIENT_REGISTRY}"
SERVER_IFACE="${SERVER_IFACE}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"
SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY}"
EOF

chmod 600 "${SERVER_ENV_FILE}"
ok "server.env saved to ${SERVER_ENV_FILE}"

# =============================================================================
# STEP 12 — Copy management scripts
# =============================================================================
section "Installing Management Scripts"

# Copy scripts to /usr/local/bin for system-wide access
SCRIPTS_SOURCE="${SCRIPT_DIR}/scripts"
if [[ -d "$SCRIPTS_SOURCE" ]]; then
    for script in "${SCRIPTS_SOURCE}"/*.sh; do
        script_name=$(basename "$script")
        cp "$script" "/usr/local/bin/wgvpn-${script_name%.sh}"
        chmod 755 "/usr/local/bin/wgvpn-${script_name%.sh}"
    done
    ok "Management scripts installed to /usr/local/bin/wgvpn-*"
fi

# =============================================================================
# STEP 13 — Final status report
# =============================================================================
section "Installation Complete!"

echo ""
echo -e "  ${GREEN}${BOLD}WireGuard VPN is installed and running!${NC}"
echo ""
echo -e "  ${BOLD}Server Information:${NC}"
echo -e "    Public IP   : ${CYAN}${SERVER_PUBLIC_IP}${NC}"
echo -e "    VPN IP      : ${CYAN}${WG_SERVER_IP}${NC}"
echo -e "    Port        : ${CYAN}${WG_PORT}/UDP${NC}"
echo -e "    Interface   : ${CYAN}${WG_INTERFACE}${NC}"
echo -e "    Public Key  : ${CYAN}${SERVER_PUBLIC_KEY}${NC}"
echo ""
echo -e "  ${BOLD}Next Steps:${NC}"
echo -e "    1. Add your first client:"
echo -e "       ${YELLOW}sudo ./scripts/add-client.sh alice${NC}"
echo ""
echo -e "    2. Show QR code for mobile:"
echo -e "       ${YELLOW}sudo ./scripts/show-qr.sh alice${NC}"
echo ""
echo -e "    3. Check VPN status:"
echo -e "       ${YELLOW}sudo wg show${NC}"
echo ""
echo -e "  ${BOLD}Useful Commands:${NC}"
echo -e "    Status     : sudo systemctl status wg-quick@wg0"
echo -e "    Restart    : sudo systemctl restart wg-quick@wg0"
echo -e "    Stop       : sudo systemctl stop wg-quick@wg0"
echo -e "    Logs       : sudo journalctl -u wg-quick@wg0 -f"
echo -e "    Peers      : sudo wg show"
echo ""

# Show current WireGuard status
echo -e "  ${BOLD}Current WireGuard Status:${NC}"
wg show 2>/dev/null || true

echo ""
ok "Installation finished at $(date)"
echo ""
