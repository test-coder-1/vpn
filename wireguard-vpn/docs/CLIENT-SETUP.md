# 📱 Client Setup Guide — Connect from Every Platform

---

## Before You Connect

You'll need:
1. Your client `.conf` file (downloaded from server or QR code)
2. The WireGuard app installed on your device

---

## 🪟 Windows

### Step 1 — Install WireGuard
1. Download from **https://www.wireguard.com/install/**
2. Run the installer (no special settings needed)

### Step 2 — Import your config
1. Open WireGuard from the system tray
2. Click **"Add Tunnel"** → **"Import tunnel(s) from file"**
3. Select your `.conf` file (e.g., `alice.conf`)

### Step 3 — Connect
1. Select the tunnel in the list
2. Click **"Activate"**
3. The toggle turns green when connected

### Step 4 — Verify
Open a browser and go to:
- `https://whatismyipaddress.com` — should show your VPN server's IP
- `https://dnsleaktest.com` — DNS should show Cloudflare/Google, not your ISP

### Kill switch on Windows
WireGuard for Windows has a built-in kill switch:
- Click **"Edit"** on your tunnel
- Check **"Block untunneled traffic (kill-switch)"**

### Common Windows issues
```
Error: "The system cannot find the file specified"
Fix: Run WireGuard as Administrator

Error: DNS not working
Fix: Check that your DNS is set to 1.1.1.1 in the config
     Go to Network Settings → Ethernet → DNS → Set manually
```

---

## 🐧 Linux

### Step 1 — Install WireGuard
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install wireguard wireguard-tools resolvconf

# Fedora
sudo dnf install wireguard-tools

# Arch Linux
sudo pacman -S wireguard-tools
```

### Step 2 — Install your config
```bash
# Copy the config to /etc/wireguard/
sudo cp alice.conf /etc/wireguard/wg0.conf

# Restrict permissions (IMPORTANT — config has your private key!)
sudo chmod 600 /etc/wireguard/wg0.conf
sudo chown root:root /etc/wireguard/wg0.conf
```

### Step 3 — Connect (manual, one-time)
```bash
# Bring up the VPN interface manually
sudo wg-quick up wg0

# Check it's working
sudo wg show

# Check your IP changed
curl https://api.ipify.org
```

### Step 4 — Connect (automatic on boot)
```bash
# Enable auto-start via systemd
sudo systemctl enable --now wg-quick@wg0

# Check status
systemctl status wg-quick@wg0
```

### Step 5 — Disconnect
```bash
# Bring down the VPN
sudo wg-quick down wg0

# Or stop the service
sudo systemctl stop wg-quick@wg0
```

### Useful Linux commands
```bash
# Check current connection status
sudo wg show

# See real-time peer stats
watch -n 1 sudo wg show

# Check routing table (should see 0.0.0.0/0 via wg0)
ip route show table main

# Check DNS
cat /etc/resolv.conf

# Test DNS for leaks
nslookup whoami.akamai.net
```

### Split tunnel on Linux
```bash
# Edit your /etc/wireguard/wg0.conf
# Change:
AllowedIPs = 0.0.0.0/0, ::/0
# To (only route VPN subnet through VPN):
AllowedIPs = 10.100.0.0/24
```

---

## 🍎 macOS

### Step 1 — Install WireGuard
Option A — App Store (recommended):
1. Open App Store
2. Search "WireGuard"
3. Install (it's free, made by the WireGuard team)

Option B — Homebrew:
```bash
brew install wireguard-tools
```

### Step 2 — Import config (App Store version)
1. Open WireGuard from Applications
2. Click **"+"** → **"Import tunnel(s) from file"**
3. Select your `.conf` file

### Step 3 — Connect
1. Click the tunnel name
2. Click **"Activate"**

### Step 4 — Connect via CLI (Homebrew version)
```bash
# Copy config
sudo cp alice.conf /etc/wireguard/wg0.conf

# Connect
sudo wg-quick up wg0

# Check status
sudo wg show

# Disconnect
sudo wg-quick down wg0
```

### Kill switch on macOS
The client config's `PostUp`/`PostDown` kill switch rules use Linux iptables.
On macOS, use **PF (Packet Filter)** instead, or rely on the app's built-in option:
1. In the WireGuard app → Edit tunnel → **"On-Demand"** → Enable

---

## 🤖 Android

### Step 1 — Install WireGuard
- Google Play: **"WireGuard"** by WireGuard Development Team (free)

### Option A — Import via QR Code (easiest)
On the server:
```bash
sudo ./scripts/show-qr.sh alice
```
On Android:
1. Open WireGuard app
2. Tap **"+"** → **"Scan from QR code"**
3. Point camera at the QR code in your terminal
4. Name the tunnel and tap **"Create Tunnel"**

### Option B — Import config file
1. Copy the `alice.conf` to your phone (via email, USB, or secure file transfer)
2. In WireGuard app: **"+"** → **"Import from file or archive"**
3. Navigate to the `.conf` file

### Step 3 — Connect
1. Tap the toggle next to your tunnel name
2. Accept the VPN permission dialog
3. Status changes to "Connected"

### Android settings
- **Always-on VPN**: Settings → Network → VPN → WireGuard → ⚙ → Enable "Always-on VPN"
- **Block connections without VPN** (kill switch): Same menu → Enable "Block connections without VPN"

---

## 🍎 iPhone / iPad (iOS)

### Step 1 — Install WireGuard
- App Store: Search **"WireGuard"** by WireGuard Development Team (free)

### Option A — Import via QR Code (easiest)
On the server:
```bash
sudo ./scripts/show-qr.sh alice
```
On iPhone:
1. Open WireGuard app
2. Tap **"+"** → **"Create from QR code"**
3. Allow camera access
4. Scan the QR code on your server screen
5. Name the tunnel → **"Save"**

### Option B — Import via file
1. AirDrop the `.conf` file to your iPhone
2. When asked how to open it, choose **WireGuard**

### Step 3 — Connect
1. Tap the tunnel name
2. Tap the toggle
3. Allow VPN configuration in iOS settings

### iOS Always-On VPN
1. Settings → General → VPN & Device Management → VPN
2. Tap the **ⓘ** next to WireGuard
3. Enable **"Connect On Demand"**
4. Add domains/networks to always route through VPN

---

## 🔍 Verifying Your Connection

After connecting on any platform:

### 1. Check your IP changed
```bash
# Your public IP should now be your VPN server's IP
curl https://api.ipify.org
# or visit: https://whatismyipaddress.com
```

### 2. Test DNS leaks
```
Visit: https://dnsleaktest.com
Click: Extended test
Result: Should show Cloudflare (1.1.1.1) or Google (8.8.8.8) — NOT your ISP
```

### 3. Test WebRTC leaks (in browser)
```
Visit: https://browserleaks.com/webrtc
Result: Should show your VPN server's IP — NOT your real IP
```

### 4. Test IPv6 leaks
```
Visit: https://ipv6leak.com
Result: Should show VPN server's IPv6 or "No IPv6 address detected"
```

---

## 🚨 Troubleshooting Connection Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Can't connect at all | Port 51820 blocked | Check server firewall: `sudo ufw status` |
| Connected but no internet | IP forwarding off | `sudo sysctl net.ipv4.ip_forward` should be `1` |
| Connected but slow | MTU mismatch | Lower MTU to 1280 in both client and server |
| DNS not working | DNS leak | Check `DNS = ` in client config |
| Disconnects frequently | NAT timeout | Ensure `PersistentKeepalive = 25` |
| Can't ping server | Firewall | Allow ICMP or use `nc -u server-ip 51820` |

```bash
# On server — check if port 51820 is open
sudo ss -ulnp | grep 51820

# On server — check WireGuard is listening
sudo wg show

# On client — check handshake happened
sudo wg show
# "latest handshake" should show recent time (< 3 min ago)

# Ping the server's VPN IP
ping 10.100.0.1

# Traceroute to verify traffic goes through VPN
traceroute 8.8.8.8
# First hop should be 10.100.0.1 (VPN server)
```
