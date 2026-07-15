# 🔬 How WireGuard Works — Deep Technical Explanation

This document explains WireGuard's internal mechanics, cryptography, and networking
concepts — designed for someone with intermediate programming knowledge.

---

## 1. What Is WireGuard?

WireGuard is a modern VPN protocol implemented as a **Linux kernel module** (and
userspace app for other OS). Unlike OpenVPN (TLS-based) or IPSec (complex),
WireGuard is:

- **~4,000 lines of code** (IPSec is ~400,000)
- Runs **inside the kernel** → no userspace copying → extremely fast
- Uses only **5 cryptographic primitives** (all modern, none deprecated)
- **Stateless handshake** — no session tracking in the traditional sense
- Uses **UDP only** (not TCP)

---

## 2. The Cryptographic Primitives

WireGuard uses **exactly 5 algorithms**, all chosen for speed and security:

| Purpose | Algorithm | Why |
|---------|-----------|-----|
| Key exchange | **Curve25519** | Elliptic-curve Diffie-Hellman. Fast, no patent issues |
| Encryption | **ChaCha20-Poly1305** | Authenticated encryption. Faster than AES on non-hardware-AES CPUs |
| Hashing | **BLAKE2s** | Faster than SHA-256, better than MD5 |
| Handshake hash | **BLAKE2s** | Used in the Noise protocol framework |
| MAC (table keys) | **SipHash-2-4** | Prevents DoS via hashtable flooding |

### Why ChaCha20 over AES?
On devices **without** hardware AES acceleration (phones, Raspberry Pi), ChaCha20 is
significantly faster. On modern Intel/AMD CPUs **with** AES-NI, performance is similar.
WireGuard uses ChaCha20 everywhere for **consistency** and **simplicity**.

---

## 3. The Noise Protocol Framework

WireGuard uses the **Noise_IKpsk2** handshake pattern from the
[Noise Protocol Framework](http://noiseprotocol.org/).

Think of Noise as a specification for how two parties exchange keys and authenticate
each other. WireGuard's specific variant provides:

- **Mutual authentication** (both sides prove they hold their private keys)
- **Forward secrecy** (past traffic can't be decrypted if current keys leak)
- **Identity hiding** (the responder's identity is encrypted before being sent)
- **Replay protection**

---

## 4. Public/Private Key Cryptography

### Generating a keypair

```bash
# Generate private key
wg genkey > private.key

# Derive public key from private key
wg pubkey < private.key > public.key
```

Under the hood:
- `wg genkey` reads 32 random bytes from `/dev/urandom`
- Applies **Curve25519 clamping** (clears 3 bits, sets specific bits for security)
- The result is your **private key**: 32 bytes, Base64-encoded

The **public key** is derived by multiplying the private key by the Curve25519 base
point (a specific mathematical operation on an elliptic curve).

**Critical property**: You can compute `public = private × base_point`, but you
**cannot** reverse it to find `private` from `public`. This is the **discrete
logarithm problem** — computationally infeasible with 256-bit keys.

### How two peers authenticate

When server and client want to communicate:
1. Server has: `server_private`, `server_public`
2. Client has: `client_private`, `client_public`
3. Both parties independently compute the **same shared secret**:
   ```
   server computes: shared = DH(server_private, client_public)
   client computes: shared = DH(client_private, server_public)
   ```
   This works because of the **Diffie-Hellman** property:
   ```
   a*G * b = b*G * a = ab*G
   ```
   Neither party sent the shared secret over the network — they each computed it
   locally. An eavesdropper who sees `a*G` and `b*G` cannot compute `ab*G` without
   solving the discrete log problem.

---

## 5. The Handshake Process

WireGuard performs a **2-message handshake** (called `Initiation` + `Response`):

```
Client                              Server
  |                                   |
  |──── Handshake Initiation ─────────>|
  |    (encrypted with server pubkey)  |
  |                                   |
  |<─── Handshake Response ────────────|
  |    (encrypted with client pubkey)  |
  |                                   |
  |════ Encrypted Data Packets ═══════>|
  |<═══ Encrypted Data Packets ════════|
```

### What's in each message?

**Initiation message** (client → server):
- Sender index (a random ID for this session)
- Ephemeral public key (fresh Curve25519 key, generated just for this handshake)
- Static public key (encrypted — proves who the client is)
- Timestamp (prevents replay attacks)
- MAC1, MAC2 (message authentication codes, prevent spoofing)

**Response message** (server → client):
- Sender index
- Receiver index (from initiation)
- Ephemeral public key (server's fresh key)
- Nothing else — authentication is implicit

### Why two ephemeral keys?

Each handshake generates **new ephemeral Curve25519 keys** (thrown away after).
This provides **forward secrecy**: if your long-term keys leak in the future, past
encrypted traffic cannot be decrypted because the ephemeral keys are gone.

### Key derivation chain

After the handshake, both sides compute session keys:
```
chaining_key → hash → handshake_hash
                    → transport_keys (send_key, recv_key)
```

The transport keys are used for all subsequent data packets. They are **rotated
every 3 minutes or 2^64 packets** (whichever comes first) via a new handshake.

---

## 6. Data Packet Encryption

Every data packet:
1. Is **encapsulated** inside a UDP packet
2. Gets a **4-byte receiver index** (server knows which peer it came from)
3. Gets a **8-byte counter** (nonce — must be monotonically increasing)
4. Is **encrypted** with ChaCha20-Poly1305 using the session key + counter as nonce
5. Has a **16-byte authentication tag** (proves it wasn't tampered with)

```
Original IP packet → [WG Header | Encrypted+Auth Payload] → UDP → Network
```

The counter prevents replay attacks: if someone captures an encrypted packet and
re-sends it, the server detects the counter is out of order and drops it.

---

## 7. Routing and AllowedIPs

WireGuard has a concept called **AllowedIPs** — the most important configuration setting.

**On the server**, a client's AllowedIPs says:
> "Accept packets FROM this peer only if the decrypted source IP is in this list"

**On the client**, the server's AllowedIPs says:
> "Send packets TO the VPN tunnel if the destination IP is in this list"

This is called **cryptorouting** — routing based on cryptographic identity.

### Full tunnel (route ALL traffic through VPN):
```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

### Split tunnel (only route VPN subnet through VPN):
```ini
AllowedIPs = 10.100.0.0/24
```

---

## 8. NAT (Network Address Translation)

When a VPN client routes ALL traffic through the VPN (full tunnel):

1. Client sends a packet to `8.8.8.8` (Google DNS)
2. Packet goes through the VPN tunnel, arrives at the server as:
   - Source: `10.100.0.2` (client VPN IP)
   - Destination: `8.8.8.8`
3. Server's iptables NAT rule fires:
   ```
   -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
   ```
4. The source IP is **rewritten** to the server's public IP (e.g., `1.2.3.4`)
5. Google sees the packet as coming from `1.2.3.4`, responds to `1.2.3.4`
6. Server receives the reply, NAT table knows it belongs to `10.100.0.2`
7. Server forwards reply back through VPN tunnel to the client

The client **thinks** it's talking directly to the internet. The internet **thinks**
all requests come from the server's public IP.

---

## 9. IP Forwarding

IP forwarding (`net.ipv4.ip_forward = 1`) enables the Linux kernel to **act as a
router** — accepting packets from one interface and forwarding them out another.

Without it:
- Packet arrives on `wg0` (VPN interface) from client
- Kernel sees destination is `8.8.8.8`
- Kernel drops the packet (it's not destined for this machine!)

With IP forwarding enabled:
- Kernel sees destination is `8.8.8.8`
- Checks routing table: "send via `eth0`"
- NAT rule rewrites source IP
- Packet is forwarded out to the internet

---

## 10. DNS and DNS Leak Prevention

When a client connects with `DNS = 1.1.1.1, 8.8.8.8` in their config:
- `wg-quick` writes a new `/etc/resolv.conf` or configures `systemd-resolved`
- All DNS queries go through the VPN tunnel to `1.1.1.1`
- Your ISP cannot see your DNS queries

**DNS leak**: If DNS queries bypass the VPN and go through the ISP's DNS server,
your browsing is visible even though data packets go through the VPN.

To check for DNS leaks after connecting: `https://dnsleaktest.com`

---

## 11. The Kill Switch

The kill switch in the client config uses iptables to **block all outbound traffic
that doesn't go through the WireGuard interface**:

```bash
iptables -I OUTPUT ! -o wg0 \
    -m mark ! --mark $(wg show wg0 fwmark) \
    -m addrtype ! --dst-type LOCAL \
    -j REJECT
```

Breaking this down:
- `-I OUTPUT`: Insert rule into the OUTPUT chain (outgoing packets)
- `! -o wg0`: Packets NOT going out through wg0
- `-m mark ! --mark $(wg show wg0 fwmark)`: Not marked by WireGuard (WireGuard marks
  its own packets to exempt them from this rule, preventing a routing loop)
- `-m addrtype ! --dst-type LOCAL`: Not going to a local address (localhost is fine)
- `-j REJECT`: Drop these packets

If the VPN drops: all traffic is blocked → no data leaks → user sees "no internet"
instead of unencrypted traffic.

---

## 12. Performance Tuning

### Why WireGuard is fast

1. **Kernel space**: Unlike OpenVPN which works in userspace, WireGuard processes
   packets in the Linux kernel, avoiding expensive context switches
2. **Simple code path**: ~4,000 lines vs hundreds of thousands for OpenVPN/IPSec
3. **ChaCha20**: Very fast on CPUs without AES-NI hardware acceleration
4. **UDP**: No TCP handshaking, no retransmission overhead at VPN layer

### Tuning parameters

```bash
# Increase kernel socket buffer sizes (for high-throughput servers)
sysctl -w net.core.rmem_max=67108864
sysctl -w net.core.wmem_max=67108864
sysctl -w net.core.rmem_default=65536
sysctl -w net.core.wmem_default=65536

# Increase the networking stack's backlog
sysctl -w net.core.netdev_max_backlog=5000

# Optimize for throughput (not latency)
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq
```

### MTU selection

```
Internet MTU (1500)
  - IP header (20 bytes)
  - UDP header (8 bytes)
  - WireGuard header (32 bytes)
  - WireGuard auth tag (16 bytes)
= 1424 bytes overhead → use MTU 1420 for safety margin
```

Lower MTU = more packet splitting overhead.  
Higher MTU = potential fragmentation if network has lower MTU.

---

## 13. WireGuard vs OpenVPN vs IPSec

| Feature | WireGuard | OpenVPN | IPSec |
|---------|-----------|---------|-------|
| Code size | ~4K lines | ~100K lines | ~400K lines |
| Handshake | 1 round-trip | 2+ round-trips | 2 round-trips |
| Protocol | UDP only | UDP or TCP | UDP |
| Roaming | Seamless | Reconnects needed | Reconnects needed |
| Config | Simple | Complex | Very complex |
| Mobile battery | Excellent | Good | Poor |
| Audit surface | Tiny | Large | Enormous |
| Performance | Excellent | Good | Good |
