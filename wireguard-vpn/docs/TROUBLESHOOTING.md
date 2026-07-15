# 🔧 Troubleshooting Guide

---

## Quick Diagnostic Checklist

Run these commands first when anything isn't working:

```bash
# 1. Is WireGuard running?
sudo systemctl status wg-quick@wg0

# 2. Is the interface up?
ip link show wg0

# 3. Does WireGuard show peers?
sudo wg show

# 4. Is the port open?
sudo ss -ulnp | grep 51820

# 5. Are firewall rules correct?
sudo ufw status verbose
sudo iptables -t nat -L -n -v

# 6. Is IP forwarding enabled?
sysctl net.ipv4.ip_forward     # Should be 1
sysctl net.ipv6.conf.all.forwarding  # Should be 1

# 7. Check recent logs
sudo journalctl -u wg-quick@wg0 -n 50 --no-pager
```

---

## Problem: WireGuard Won't Start

### Error: `RTNETLINK answers: Operation not permitted`

**Cause**: Missing `CAP_NET_ADMIN` capability or not running as root.

```bash
# Fix: Always run wg-quick as root
sudo wg-quick up wg0

# If using systemd service, check it runs as root
systemctl cat wg-quick@wg0 | grep User
```

### Error: `Cannot find device "wg0"`

**Cause**: WireGuard kernel module not loaded.

```bash
# Load the module manually
sudo modprobe wireguard

# Check if it loaded
lsmod | grep wireguard

# If missing, install wireguard-tools
sudo apt install --reinstall wireguard wireguard-tools
```

### Error: `wg0.conf: [Errno 13] Permission denied`

**Cause**: Incorrect file permissions on wg0.conf.

```bash
# Fix permissions
sudo chmod 600 /etc/wireguard/wg0.conf
sudo chown root:root /etc/wireguard/wg0.conf
```

### Error: `Address already in use (port 51820)`

**Cause**: Another process is using UDP port 51820.

```bash
# Find what's using the port
sudo ss -ulnp | grep 51820

# Kill the process
sudo kill <PID>

# Or change the WireGuard port in wg0.conf
# ListenPort = 51821
```

---

## Problem: Can Connect But No Internet

This is the most common issue. VPN connects (handshake succeeds) but internet doesn't work.

### Check 1: IP Forwarding

```bash
# Must be 1 (enabled)
cat /proc/sys/net/ipv4/ip_forward

# Fix if 0
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
# Make permanent:
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-wireguard.conf
sudo sysctl -p /etc/sysctl.d/99-wireguard.conf
```

### Check 2: NAT Rules

```bash
# Check NAT rules exist
sudo iptables -t nat -L POSTROUTING -n -v

# Should see a line like:
# MASQUERADE  all  --  10.100.0.0/24    0.0.0.0/0

# If missing, add manually (replace eth0 with your interface)
sudo iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE

# Or restart WireGuard (PostUp rules will re-add them)
sudo systemctl restart wg-quick@wg0
```

### Check 3: FORWARD chain

```bash
# Check FORWARD rules
sudo iptables -L FORWARD -n -v

# Should see ACCEPT rules for wg0
# If missing:
sudo iptables -A FORWARD -i wg0 -j ACCEPT
sudo iptables -A FORWARD -o wg0 -j ACCEPT
```

### Check 4: Server interface name

```bash
# Find the correct interface name (not always eth0!)
ip route get 1.1.1.1
# Look for "dev eth0" or "dev ens3" or "dev enp0s3"

# Check wg0.conf PostUp/PostDown lines match your interface
grep "PostUp" /etc/wireguard/wg0.conf
# Should say: -o eth0   (or whatever your interface is)

# If wrong, update wg0.conf and restart
sudo nano /etc/wireguard/wg0.conf
# Change eth0 to your actual interface name
sudo systemctl restart wg-quick@wg0
```

### Check 5: UFW blocking forwarded traffic

```bash
# Check UFW forward policy
grep DEFAULT_FORWARD_POLICY /etc/default/ufw
# Should be: DEFAULT_FORWARD_POLICY="ACCEPT"

# Fix if DROP:
sudo sed -i 's/DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

---

## Problem: Client Can't Connect At All

### Check: Port is reachable

```bash
# ON CLIENT — test if UDP port 51820 is open
nc -u -z -v <server-ip> 51820
# If "Connection refused" or timeout — port is blocked

# ON SERVER — check port is listening
sudo ss -ulnp | grep 51820
# Should show: udp 0 0 0.0.0.0:51820

# ON SERVER — check UFW allows the port
sudo ufw status | grep 51820
```

### Check: Server public IP is correct

```bash
# What IP does the server think it has?
curl https://api.ipify.org

# What IP is in client config?
grep Endpoint /etc/wireguard/wg0.conf
```

### Check: Keys match

```bash
# ON SERVER
cat /etc/wireguard/server_public.key

# This MUST match the PublicKey in the client's [Peer] section
grep PublicKey /etc/wireguard/clients/alice/alice.conf
```

### Check: Time synchronization

WireGuard handshake timestamps expire after 3 minutes. If your server clock is
wrong, handshakes will fail.

```bash
# Check server time
date

# Sync time with NTP
sudo systemctl enable --now systemd-timesyncd
sudo timedatectl set-ntp true
timedatectl status
```

---

## Problem: VPN Disconnects Frequently

### Cause: NAT timeout

If the client is behind a router (home NAT), the router's NAT table entry expires
after inactivity.

```bash
# Fix: Ensure PersistentKeepalive is set in client config
grep PersistentKeepalive /etc/wireguard/clients/alice/alice.conf
# Should be: PersistentKeepalive = 25

# If missing, regenerate the client config or add it manually
sudo nano /etc/wireguard/clients/alice/alice.conf
# Add to [Peer] section:
# PersistentKeepalive = 25

# Also update on the actual client device
```

### Cause: MTU mismatch causing fragmentation

```bash
# Test actual usable MTU (from client, pinging server)
ping -M do -s 1400 10.100.0.1   # Increase/decrease size to find max

# Lower the MTU in both server and client config
# In wg0.conf [Interface]: MTU = 1280
# In client config [Interface]: MTU = 1280

# Restart WireGuard after changing MTU
sudo systemctl restart wg-quick@wg0
```

---

## Problem: DNS Not Working / DNS Leaks

### Check: DNS configuration in client

```bash
# In client config, verify DNS line
grep DNS /etc/wireguard/wg0.conf
# Should be: DNS = 1.1.1.1,8.8.8.8
```

### Fix: resolvconf not updating

```bash
# Install resolvconf
sudo apt install resolvconf

# Check resolv.conf after connecting
cat /etc/resolv.conf
# Should show nameserver 1.1.1.1 and 8.8.8.8 when VPN is up

# If systemd-resolved is used (Ubuntu 24.04 default)
resolvectl status
```

### Fix: DNS leak through systemd-resolved

```bash
# Check which DNS systemd-resolved is using
resolvectl status | grep "DNS Servers"

# Set DNS for the WireGuard interface specifically
# Add to client wg0.conf [Interface]:
# DNS = 1.1.1.1,8.8.8.8
# PostUp = resolvectl dns %i 1.1.1.1 8.8.8.8; resolvectl domain %i "~."
# PostDown = resolvectl revert %i
```

---

## Problem: Slow VPN Speeds

### Check: CPU saturation

```bash
# Check CPU usage during VPN transfer
top
# Look for high wireguard or kworker CPU usage

# Check AES hardware acceleration
grep -m1 -o aes /proc/cpuinfo
# "aes" = has hardware AES acceleration

# On ARM devices without AES-NI, ChaCha20 is used (default in WireGuard)
# No action needed — this is expected
```

### Check: MTU performance

```bash
# Test raw VPN speed
iperf3 -s                    # On server inside VPN
iperf3 -c 10.100.0.1        # On client

# If slow, try adjusting MTU:
# Lower MTU = less fragmentation but more overhead
# Common sweet spots: 1280, 1380, 1420
```

### Optimize: Enable BBR congestion control

```bash
# Add to /etc/sysctl.d/99-wireguard.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Apply
sudo sysctl -p /etc/sysctl.d/99-wireguard.conf

# Verify BBR is active
sysctl net.ipv4.tcp_congestion_control
```

---

## Problem: Fail2Ban Blocking Legitimate Access

```bash
# Check if your IP is banned
sudo fail2ban-client status sshd

# Unban your IP
sudo fail2ban-client set sshd unbanip <your-ip>

# Check all banned IPs
sudo fail2ban-client status

# View Fail2Ban log
sudo tail -50 /var/log/fail2ban.log
```

---

## Useful Monitoring Commands

```bash
# ── WireGuard status ──────────────────────────────────────────────────────────
sudo wg show                          # Current state of all interfaces
sudo wg show wg0                      # Specific interface
sudo wg show wg0 dump                 # Machine-readable (tab-separated)
sudo wg show wg0 latest-handshakes    # Last handshake time per peer
sudo wg show wg0 transfer             # Bytes sent/received per peer
sudo wg show wg0 endpoints            # Connected endpoint per peer

# ── Interface and routing ─────────────────────────────────────────────────────
ip addr show wg0                      # VPN interface details
ip route show table main              # Routing table
ip route show table all               # All routing tables (including WG)

# ── Network connections ───────────────────────────────────────────────────────
ss -ulnp                              # All UDP listening ports
ss -tnp                               # All TCP connections
netstat -rn                           # Routing table (older alternative)

# ── Firewall ──────────────────────────────────────────────────────────────────
sudo ufw status verbose               # UFW rules
sudo iptables -L -n -v                # All iptables rules
sudo iptables -t nat -L -n -v         # NAT table rules
sudo ip6tables -t nat -L -n -v        # IPv6 NAT rules

# ── System logs ───────────────────────────────────────────────────────────────
sudo journalctl -u wg-quick@wg0 -f   # Follow WireGuard logs
sudo journalctl -u fail2ban -n 20    # Recent Fail2Ban activity
sudo tail -f /var/log/ufw.log        # UFW firewall log
sudo tail -f /var/log/auth.log       # Authentication log (SSH)

# ── Performance ───────────────────────────────────────────────────────────────
htop                                  # Process monitor
iftop -i wg0                          # Network traffic on wg0
vnstat -i wg0                         # Traffic statistics (requires vnstat)
```

---

## Resetting Everything

If you want a completely fresh start:

```bash
# Stop WireGuard
sudo systemctl stop wg-quick@wg0

# Remove all configs (THIS DELETES EVERYTHING)
sudo rm -rf /etc/wireguard

# Re-run the installer
sudo ./install.sh
```
