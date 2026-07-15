# ☁️ Deployment Guide — Cloud Providers & Home Setup

---

## Overview

This guide covers deploying your WireGuard VPN server on:
1. AWS EC2
2. Azure VM
3. DigitalOcean Droplet
4. Oracle Cloud Free Tier
5. Raspberry Pi
6. Home PC / Router

---

## 🟧 AWS EC2

### Step 1 — Create an EC2 Instance

1. Sign in to [AWS Console](https://console.aws.amazon.com)
2. Navigate to **EC2 → Launch Instance**
3. Configure:
   - **Name**: `wireguard-vpn`
   - **AMI**: Ubuntu Server 24.04 LTS (look for "Ubuntu 24.04" in Quick Start)
   - **Instance type**: `t3.micro` (Free Tier eligible, or `t3.nano` for minimal cost)
   - **Key pair**: Create new → Download the `.pem` file → **KEEP THIS SAFE**
   - **Network settings**: Allow SSH (port 22) from your IP
4. Click **Launch Instance**

### Step 2 — Configure Security Group (Firewall)

1. Navigate to **EC2 → Security Groups**
2. Find the security group for your instance
3. Click **Edit inbound rules** → **Add rule**:
   - Type: **Custom UDP**
   - Port: **51820**
   - Source: **Anywhere-IPv4** (0.0.0.0/0)
   - Description: WireGuard VPN
4. **Save rules**

### Step 3 — Connect to your instance

```bash
# Fix key file permissions (AWS requires private key to be read-only by owner)
chmod 400 /path/to/your-key.pem

# SSH into the instance
# Replace <public-ip> with your EC2 instance's public IPv4 address
ssh -i /path/to/your-key.pem ubuntu@<public-ip>
```

### Step 4 — Run the installer

```bash
# Switch to root
sudo -i

# Clone this project
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn

# Make scripts executable
chmod +x install.sh uninstall.sh scripts/*.sh

# Install
./install.sh
```

### Step 5 — Allocate an Elastic IP (IMPORTANT!)

By default, EC2 instances get a **different public IP every time they restart**.
You need an Elastic IP (static IP) so your clients always know the server address.

1. EC2 Console → **Elastic IPs** → **Allocate Elastic IP address** → **Allocate**
2. Select the new IP → **Actions** → **Associate Elastic IP address**
3. Select your instance → **Associate**
4. Update your client configs to use the Elastic IP as the `Endpoint`

### AWS-specific notes
- **Region**: Choose the region closest to your primary usage location
- **Storage**: 8GB gp3 is sufficient for a VPN-only server
- **Cost**: t3.micro ~$8/month, Elastic IP free when attached to running instance

---

## 🔷 Azure VM

### Step 1 — Create a Virtual Machine

1. Sign in to [Azure Portal](https://portal.azure.com)
2. **Create a resource** → **Virtual Machine**
3. Configure:
   - **Resource group**: Create new `rg-wireguard`
   - **VM name**: `wireguard-vpn`
   - **Region**: Choose nearest to you
   - **Image**: Ubuntu Server 24.04 LTS
   - **Size**: Standard_B1s (1 vCPU, 1GB RAM — ~$8/month)
   - **Authentication**: SSH public key (upload your `~/.ssh/id_rsa.pub`)
   - **Public inbound ports**: Allow SSH (22)
4. Click **Review + create** → **Create**

### Step 2 — Open WireGuard Port

After deployment:
1. Go to your VM → **Networking** → **Add inbound port rule**
2. Configure:
   - Destination port: **51820**
   - Protocol: **UDP**
   - Action: **Allow**
   - Name: `WireGuard`
3. **Add**

### Step 3 — Get a Static IP

1. VM → **IP configuration** → Click your public IP
2. **Assignment**: Change from **Dynamic** to **Static**
3. **Save**

### Step 4 — Connect and Install

```bash
# Connect
ssh -i ~/.ssh/id_rsa azureuser@<your-static-ip>

# Install
sudo -i
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn
chmod +x install.sh scripts/*.sh
./install.sh
```

---

## 🟦 DigitalOcean Droplet

DigitalOcean is often the simplest cloud option for self-hosting.

### Step 1 — Create a Droplet

1. Sign in to [DigitalOcean](https://www.digitalocean.com)
2. **Create** → **Droplets**
3. Configure:
   - **Image**: Ubuntu 24.04 LTS
   - **Plan**: Shared CPU → Basic → $6/month (1 vCPU, 1GB RAM)
   - **Datacenter region**: Choose the closest
   - **Authentication**: SSH Key (upload your public key, or use a password)
   - **Hostname**: `wireguard-vpn`
4. **Create Droplet**

### Step 2 — Configure Firewall

1. **Networking** → **Firewalls** → **Create Firewall**
2. Add inbound rules:
   - **SSH**: TCP port 22 (from your IP for security)
   - **WireGuard**: UDP port 51820 (All IPv4, All IPv6)
3. Apply to your Droplet

### Step 3 — Connect and Install

```bash
# DigitalOcean assigns a static IP by default!
# Connect directly
ssh root@<droplet-ip>

# Install
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn
chmod +x install.sh scripts/*.sh
./install.sh
```

### DigitalOcean advantages
- Static IP by default (no extra config needed)
- Simple web UI
- One-click server snapshots (easy backup)
- $6/month for a capable VPN server

---

## 🟡 Oracle Cloud Free Tier (Always Free)

Oracle Cloud offers a **permanently free** tier that includes:
- 2x AMD VMs (1 OCPU, 1GB RAM each) — always free
- 4x ARM VMs (4 OCPU, 24GB RAM total) — always free
- 10 TB outbound bandwidth/month — free

This is the best free option for a VPN server.

### Step 1 — Create an Account

1. Sign up at [cloud.oracle.com](https://cloud.oracle.com)
2. Choose **"Free Tier"** when registering
3. Verify your account (requires credit card for verification, but won't be charged)

### Step 2 — Create a VM

1. **Compute** → **Instances** → **Create Instance**
2. Configure:
   - **Name**: `wireguard-vpn`
   - **Image**: Canonical Ubuntu 24.04 (Minimal)
   - **Shape**: VM.Standard.A1.Flex (ARM, free tier — choose 1 OCPU, 6GB RAM)
   - **Network**: Create new VCN and subnet
   - **SSH keys**: Upload your public key
3. **Create**

### Step 3 — Configure Security List (Oracle's firewall)

1. **Networking** → **Virtual Cloud Networks** → Your VCN → **Security Lists**
2. **Default Security List** → **Add Ingress Rules**
3. Add:
   - Source CIDR: `0.0.0.0/0`
   - IP Protocol: UDP
   - Destination Port Range: `51820`
   - Description: WireGuard VPN

### Step 4 — Disable iptables INPUT default REJECT

Oracle's Ubuntu images have an aggressive iptables policy. Run:

```bash
# On the Oracle instance:
# Oracle adds these rules that block everything by default
# Remove them and rely on UFW instead

sudo iptables -F INPUT
sudo iptables -P INPUT ACCEPT

# Or specifically allow WireGuard
sudo iptables -I INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# Save rules
sudo netfilter-persistent save
```

### Step 5 — Install

```bash
ssh -i ~/.ssh/id_rsa ubuntu@<oracle-public-ip>
sudo -i
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn
chmod +x install.sh scripts/*.sh
./install.sh
```

---

## 🫐 Raspberry Pi (Local Network / Home)

Great for a local VPN to access your home network remotely.

### Requirements
- Raspberry Pi 3B+, 4, or 5 (any works; Pi 4 recommended)
- MicroSD card (16GB+)
- Ethernet cable (more reliable than WiFi for a server)
- Static local IP assigned via your router's DHCP settings

### Step 1 — Flash Ubuntu Server

1. Download **Raspberry Pi Imager** from raspberrypi.com
2. Choose: **Other general-purpose OS → Ubuntu → Ubuntu Server 24.04 LTS (64-bit)**
3. Click the gear icon → Enable SSH, set username/password
4. Flash the SD card

### Step 2 — Find and connect to your Pi

```bash
# Find Pi's IP address on your network
arp -a | grep -i raspberry
# or
nmap -sn 192.168.1.0/24

# SSH in
ssh ubuntu@192.168.1.xxx
```

### Step 3 — Set a static local IP

```bash
# Find your router IP
ip route | grep default

# Edit netplan (Ubuntu's network config)
sudo nano /etc/netplan/50-cloud-init.yaml
```

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 192.168.1.100/24      # Your chosen static IP
      routes:
        - to: default
          via: 192.168.1.1      # Your router's IP
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
```

### Step 4 — Install WireGuard

```bash
sudo -i
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn
chmod +x install.sh scripts/*.sh
./install.sh
```

### Step 5 — Port forwarding on your home router

This is the critical step for home deployment. You need to tell your router to
forward WireGuard traffic to your Pi.

Every router is different, but the concept is the same:

**Linksys:**
1. Open a browser → go to `192.168.1.1` (your router IP)
2. Log in (default: admin/admin or printed on router)
3. **Smart Wi-Fi Tools** → **Port Range Forwarding**
4. Add rule:
   - Application: WireGuard
   - External Port: 51820
   - Internal Port: 51820
   - Protocol: UDP
   - Device IP: 192.168.1.100 (your Pi's static IP)
   - Enable: Yes

**Netgear:**
1. Browser → `192.168.1.1`
2. **Advanced** → **Advanced Setup** → **Port Forwarding**
3. **Add Custom Service**:
   - Name: WireGuard
   - Protocol: UDP
   - Port: 51820
   - Server IP: 192.168.1.100

**TP-Link:**
1. Browser → `192.168.0.1`
2. **Advanced** → **NAT Forwarding** → **Virtual Servers**
3. **Add**:
   - External Port: 51820
   - Internal IP: 192.168.1.100
   - Internal Port: 51820
   - Protocol: UDP

**ASUS:**
1. Browser → `192.168.1.1`
2. **WAN** → **Virtual Server / Port Forwarding**
3. Add entry:
   - Service Name: WireGuard
   - Protocol: UDP
   - External Port: 51820
   - Internal Port: 51820
   - Internal IP: 192.168.1.100

### Step 6 — Dynamic DNS (if no static public IP)

Home ISPs usually change your public IP periodically. You need a Dynamic DNS service
to always find your home server:

**Option A — DuckDNS (free)**
```bash
# Register a free subdomain at https://www.duckdns.org
# e.g., yourname.duckdns.org

# Create update script
cat > /etc/cron.d/duckdns << 'EOF'
*/5 * * * * root curl -s "https://www.duckdns.org/update?domains=yourname&token=your-token&ip=" > /dev/null 2>&1
EOF
```

**Option B — Cloudflare (free)**
```bash
# Use Cloudflare's free DNS with API-based auto-update
# Install cloudflare-ddns or use a simple curl script
```

**Set your client config to use the hostname:**
```ini
Endpoint = yourname.duckdns.org:51820
```

---

## 🏠 Home PC (as VPN Server)

If you want to run WireGuard on a desktop/laptop:

### Considerations
- Your PC must be **always on** when you want to connect remotely
- Same port forwarding steps as Raspberry Pi above
- Ubuntu Server installed directly or in a VM

### Running in a VM (VirtualBox/VMware)

If using a VM on Windows/macOS:
1. Set VM network adapter to **"Bridged"** (not NAT)
2. This gives the VM its own IP on your LAN
3. Port forward to the VM's IP from your router

### Power settings (keep PC awake)
```bash
# Prevent Ubuntu server from sleeping
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

---

## 📋 Post-Deployment Checklist

After deploying to any platform:

```bash
# 1. Verify WireGuard is running
sudo systemctl status wg-quick@wg0

# 2. Check the VPN interface is up
sudo wg show

# 3. Add a test client
sudo ./scripts/add-client.sh testclient

# 4. Connect from your device and verify:
#    - Your IP is now the server's IP
#    - DNS shows Cloudflare/Google, not your ISP
#    - No DNS leaks (dnsleaktest.com)

# 5. Test kill switch (disconnect WireGuard)
#    - Internet should stop immediately on the client

# 6. Test auto-restart (server reboot)
sudo reboot
# Wait 1-2 minutes, then reconnect from client
# Should work automatically

# 7. Set up automated backups
sudo crontab -e
# Add: 0 3 * * * /path/to/scripts/backup.sh
```
