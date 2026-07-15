# 🔒 WireGuard VPN — Production-Ready Self-Hosted VPN

A complete, production-ready WireGuard VPN solution for Ubuntu Server 24.04 LTS.
Supports multiple clients, QR codes, automatic firewall rules, DNS leak prevention,
kill switch, Fail2Ban integration, and full IPv4/IPv6.

---

## 📁 Project Structure

```
wireguard-vpn/
├── README.md                      # This file — full documentation
├── install.sh                     # Full server installation script
├── uninstall.sh                   # Full uninstall / cleanup script
├── scripts/
│   ├── add-client.sh              # Add a new VPN client
│   ├── remove-client.sh           # Remove a client (wipes keys + config)
│   ├── list-clients.sh            # List all registered clients
│   ├── revoke-client.sh           # Revoke a client (keeps record, blocks access)
│   ├── show-qr.sh                 # Display QR code for a client
│   ├── backup.sh                  # Backup WireGuard config + keys
│   ├── restore.sh                 # Restore from backup
│   ├── monitor.sh                 # Show live VPN status and connected peers
│   └── update-wg.sh               # Update WireGuard and system packages
├── config/
│   ├── wg0.conf.template          # Server config template
│   ├── client.conf.template       # Client config template
│   └── server.env                 # Server environment variables (generated)
├── systemd/
│   └── wg-quick@.service          # Custom systemd service override
├── fail2ban/
│   ├── jail.local                 # Fail2Ban jail configuration
│   └── filter.d/
│       └── sshd-aggressive.conf   # Aggressive SSH filter
└── docs/
    ├── HOW-WIREGUARD-WORKS.md     # Deep dive into WireGuard internals
    ├── CLIENT-SETUP.md            # How to connect from every OS
    ├── DEPLOYMENT.md              # Cloud and home deployment guide
    └── TROUBLESHOOTING.md         # Common issues and fixes
```

---

## ⚡ Quick Start

```bash
# 1. Clone or copy this project to your Ubuntu 24.04 server
git clone https://github.com/youruser/wireguard-vpn.git
cd wireguard-vpn

# 2. Make scripts executable
chmod +x install.sh uninstall.sh scripts/*.sh

# 3. Run the installer (requires root)
sudo ./install.sh

# 4. Add your first client
sudo ./scripts/add-client.sh alice

# 5. Show the QR code to scan with your phone
sudo ./scripts/show-qr.sh alice
```

---

## 🌐 Network Layout

| Role        | IP Address     | Description                  |
|-------------|----------------|------------------------------|
| VPN Server  | 10.100.0.1/24  | WireGuard tunnel endpoint    |
| Client 1    | 10.100.0.2/32  | First peer (e.g. alice)      |
| Client 2    | 10.100.0.3/32  | Second peer (e.g. bob)       |
| ...         | 10.100.0.x/32  | Additional peers              |

**VPN Subnet:** `10.100.0.0/24`  
**DNS:** `1.1.1.1, 8.8.8.8` (Cloudflare + Google)  
**Port:** `51820/UDP`  
**MTU:** `1420`  

---

## 🔑 Security Features

- Curve25519 key exchange (WireGuard default — state of the art)
- ChaCha20-Poly1305 authenticated encryption
- BLAKE2s hashing
- SipHash-2-4 hashtable keys
- No user/password authentication — key-only
- Automatic firewall rules via UFW
- DNS leak prevention
- Kill switch (blocks all traffic if VPN drops)
- Fail2Ban protecting SSH and WireGuard
- Root-only config file permissions (600)
- Automatic key rotation support

---

## 📋 Management Commands

```bash
# Add a client
sudo ./scripts/add-client.sh <name>

# Remove a client completely
sudo ./scripts/remove-client.sh <name>

# List all clients
sudo ./scripts/list-clients.sh

# Revoke a client (block without deleting)
sudo ./scripts/revoke-client.sh <name>

# Show QR code
sudo ./scripts/show-qr.sh <name>

# Live monitoring
sudo ./scripts/monitor.sh

# Backup configs
sudo ./scripts/backup.sh

# Restore from backup
sudo ./scripts/restore.sh /path/to/backup.tar.gz

# Update WireGuard
sudo ./scripts/update-wg.sh
```

---

## 📖 Documentation

- [How WireGuard Works](docs/HOW-WIREGUARD-WORKS.md)
- [Client Setup Guide](docs/CLIENT-SETUP.md)
- [Cloud Deployment Guide](docs/DEPLOYMENT.md)
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md)

---

## ⚠️ Requirements

- Ubuntu Server 24.04 LTS
- Root or sudo access
- A public IP address (or Dynamic DNS)
- Open UDP port 51820 on your firewall/router
- At least 512 MB RAM, 1 vCPU

---

*Built for production use. Tested on Ubuntu 24.04 LTS.*
