# WireGuard middle + exit server, tunneled with WaterWall

Two one-command installers that build a two-hop VPN:

```
  phone / laptop                                     your home router
        │                                                  │
        │  WireGuard (udp/51820)                           │
        ▼                                                  ▼
 ┌──────────────────────────────┐    WaterWall tunnel   ┌──────────────────────┐
 │  MIDDLE  (Proxmox LXC)       │  ───────────────────► │  EXIT  (VPS)         │
 │  · WireGuard server wg0      │   TLS 1.3 / Reality   │  · WaterWall server  │
 │  · WireGuard client wg1 ─────┼─── tcp/443 ──────────►│  · WireGuard wg0     │
 │  · WireGuard Dashboard (web) │                       │  · NAT -> internet   │
 │  · WaterWall client          │                       │                      │
 └──────────────────────────────┘                       └──────────────────────┘
                                                         5.75.197.180 (example)
```

* **Middle** = the machine your clients connect to (a new LXC on your Proxmox
  host). It runs the WireGuard server, the
  [WireGuard Dashboard](https://github.com/HusainAlhajHasan1/wireguard-dashboard)
  and the client side of the WaterWall tunnel.
* **Exit** = the VPS (your `5.75.197.180`) where the internet traffic of your
  clients actually leaves. Only it needs to be reachable from the internet on a
  TCP port.

Because the middle is behind your home router, it only needs **one forwarded UDP
port**. The middle → exit link is an *outgoing* TLS/Reality connection, so the
exit is the only side with a public listening port, and the middle works behind
NAT/CGNAT-free lines without any VPN port exposed.

---

## 1. Quick start (two commands)

### Step 1 — on the exit VPS (as root)

```bash
curl -fsSL https://raw.githubusercontent.com/HusainAlhajHasan1/waterwallwireguard/main/install-exit.sh \
  | bash
```

It prints a **JOIN TOKEN** at the end (also saved to
`/root/exit-join-token.txt`). Copy it.

### Step 2 — on the Proxmox host (as root)

```bash
curl -fsSL https://raw.githubusercontent.com/HusainAlhajHasan1/waterwallwireguard/main/install-middle.sh \
  | sudo bash -s -- --join '<paste the token>'
```

This creates the LXC container, installs everything inside it and prints:

* the container IP (e.g. `192.168.1.240`) and the dashboard URL,
* the dashboard user/password,
* **the exact router port-forward you have to add**.

That is all. Add clients in the dashboard; their configs route all traffic
through the exit.

> While this repository is on a feature branch, replace `main` in both URLs with
> the branch name, or set `WW_REF=<branch>` before the command.

### Optional flags you will likely want

```bash
# exit server: Reality camouflage, no certificate/domain needed
... install-exit.sh | bash -s -- --mode reality --port 443 --sni www.cloudflare.com

# exit server: half-duplex over TLS with a real Let's Encrypt certificate
... install-exit.sh | bash -s -- --mode halfduplex --port 443 \
    --tunnel-domain tunnel.example.com --email me@example.com

# middle: panel over HTTPS (needs tcp/80+tcp/443 forwarded to the LXC)
... install-middle.sh | sudo bash -s -- --join '<token>' \
    --dash-domain panel.example.com --dash-email me@example.com

# middle: choose the container address / size / the client UDP port
... install-middle.sh | sudo bash -s -- --join '<token>' \
    --ip 192.168.1.240/24 --cores 2 --memory 1024 --disk 8 --wg-port 51820
```

> `--join '<token>'` also works as `WW_JOIN='<token>'` in front of the command,
> which is handy when the shell history should not contain the token.

`install-exit.sh --help` and `install-middle.sh --help` list everything.

---

## 2. Ports, IPs and domains — what to open, what to create

### 2.1 Your home router (this is what clients connect to)

| Rule | Protocol | External port | Forward to (the LXC) | Needed? |
|---|---|---|---|---|
| WireGuard for clients | **UDP** | `51820` | `<LXC-IP>:51820` | **REQUIRED** |
| Dashboard HTTPS | TCP | `443` | `<LXC-IP>:443` | optional (only with `--dash-domain`) |
| Dashboard certificate | TCP | `80` | `<LXC-IP>:80` | optional (same) |

* The LXC IP is the address printed by the installer (a free address in your
  `192.168.1.0/24`, e.g. `192.168.1.240`). It is configured as a **static**
  address, so the forward keeps working after reboots.
* **Nothing else** has to be forwarded. The middle never listens on the tunnel
  port; it dials out to the exit.
* If you prefer a different client port, install with `--wg-port 443` etc. and
  forward that UDP port instead. Keep the router rule and `--wg-port` identical.

### 2.2 The exit VPS (host firewall **and** the Hetzner Cloud Firewall)

| Rule | Protocol | Port | Needed? |
|---|---|---|---|
| WaterWall tunnel | **TCP** | `443` (or your `--port`) | **REQUIRED** |
| WaterWall tunnel (split mode) | **TCP** | `444` (second port) | only `--mode split` |
| Let's Encrypt renewals | TCP | `80` | only with `--tunnel-domain` |
| SSH | TCP | `22` | for you |

The installer creates the `ww-firewall` rules on the VPS itself, **but a cloud
firewall (Hetzner console → Firewall) must be opened separately**: add rules for
the ports above to the firewall attached to the server. UDP `51820` on the VPS is
deliberately **closed** — that WireGuard socket only listens on `127.0.0.1` and
is reachable exclusively through the tunnel.

### 2.3 Domains — which one needs a domain?

| What | Domain needed? | Why |
|---|---|---|
| Clients connecting to the middle | **No** | they connect to `your-public-ip:51820` (or a DDNS name) |
| Exit tunnel in **`reality`** mode | **No** | Reality borrows the TLS certificate of a real public site (`--sni`) |
| Exit tunnel in **`halfduplex` / `split`** mode | **Optional** | without a domain it uses a self-signed certificate (`verify=false`); with `--tunnel-domain` + `--email` it gets a free Let's Encrypt certificate, which is better camouflage |
| WireGuard Dashboard (`--dash-domain`) | **Optional** | without it the panel is only on `http://<LXC-IP>:8080` inside your LAN |

If you do use domains:

1. **Tunnel domain** (`--tunnel-domain tunnel.example.com`) must have an **A
   record pointing to the exit VPS** (`5.75.197.180`), and `tcp/80` must be open
   on the VPS while the certificate is issued/renewed.
2. **Panel domain** (`--dash-domain panel.example.com`) must have an **A record
   pointing to your home public IP**, and `tcp/80` + `tcp/443` must be forwarded
   from the router to the LXC.

### 2.4 Dynamic home IP?

The client configs contain `endpoint = <public-host>:51820`. If your ISP changes
the address:

* best: install with `--public-host your-name.duckdns.org` (any DDNS name) so
  configs never go stale, or
* after a change: Dashboard → **Server** → *Endpoint* → update it, then clients
  re-download their config (or edit the `Endpoint` line in the client config).

The installer warns you if the detected public address looks like
carrier-grade NAT (`100.64.0.0/10`) — in that case port forwarding cannot work at
all and you need a real public IPv4 from your ISP.

---

## 3. The three tunnel modes

Selected with `--mode` **on the exit installer**; the middle reads it from the
join token, so both sides always match.

| Mode | Transport | Port(s) on the VPS | Certificate | When to use |
|---|---|---|---|---|
| `halfduplex` *(default)* | TLS 1.3 + WaterWall **HalfDuplex**: every logical stream is split into one upload and one download TCP connection | 1 (443) | self-signed or real | best default: looks like a normal HTTPS session pair, resists simple traffic analysis |
| `split` | TLS 1.3 + HalfDuplex, but the two half-connections are **spread over two exit ports** (the exit accepts both from one chain, the middle picks a port per connection) | 2 (443 + 444) | self-signed or real | makes the pair harder to correlate: an observer sees two unrelated TLS connections to two different ports, not a matching pair |
| `reality` | **Reality v2**: a genuine TLS 1.3 handshake with a real public HTTPS site; unauthenticated probes are relayed to that site | 1 (443) | none needed | best camouflage; no domain, no certificate, no renewal |

All three carry a **WireGuard tunnel** (middle `wg1` → exit `wg0`) inside
UDP-over-TCP framing, so the transport only has to look harmless: the payload is
already encrypted and authenticated by WireGuard.

Switching mode later: re-run the exit installer with `--mode X` (it prints a new
token), then re-run the middle installer with the new token. Existing WireGuard
keys and clients are kept.

---

## 4. Adding clients

Panel: `https://<dash-domain>` or `http://<LXC-IP>:8080` → **Peers → Add peer**.
Each peer is written into `/etc/wireguard/wg0.conf` and applied live with
`wg syncconf`.

Defaults applied by the installer so a fresh peer just works:

| Setting | Value | Why |
|---|---|---|
| `default_allowed_ips` | `0.0.0.0/0` | full tunnel through the exit |
| `default_mtu` | `1280` | the tunnel is encapsulated twice; 1280 never fragments |
| `default_dns` | `1.1.1.1, 8.8.8.8` | resolved through the tunnel |
| `default_keepalive` | `25` | keeps NAT/tunnel state alive |

CLI (inside the container, `pct enter <id>`):

```bash
wgdash add phone --days 30 --quota 50     # .conf + QR in the panel
wgdash qr phone --terminal                # scan from the terminal
wgdash list ; wgdash status ; wg show
```

**IPv6 note:** the tunnel is IPv4-only (`0.0.0.0/0`). Clients that have native
IPv6 keep using it directly, i.e. IPv6 traffic does *not* go through the exit.
If that matters for you, disable IPv6 on the client or add a second tunnel.

---

## 5. Day-2 operations

```bash
# middle (Proxmox host)
pct enter <id>                     # then:
systemctl status waterwall wg-quick@wg0 wg-quick@wg1 wireguard-dashboard wgmw-routing
wg show wg0                        # clients, handshakes, traffic
wg show wg1                        # the tunnel to the exit
journalctl -u waterwall -f         # tunnel log
tail -f /var/log/waterwall/network.log
ip rule show ; ip route show table 100     # policy routing (client -> tunnel)
wgdash status

# exit (VPS)
systemctl status waterwall wg-quick@wg0 ww-firewall
wg show wg0
iptables -t nat -L POSTROUTING -n -v       # NAT for 10.8.0.0/24
journalctl -u waterwall -f
```

A `ww-health.timer` runs every minute inside the middle container and restarts
WaterWall when the tunnel handshake has been stale for more than 5 minutes
(WireGuard keepalives keep a healthy tunnel's handshake fresh, so a stale
handshake means the tunnel is really broken).

Updating:

```bash
# re-running either installer is safe and keeps keys/config
curl -fsSL .../install-exit.sh | bash
curl -fsSL .../install-middle.sh | sudo bash -s -- --join "$(tail -1 /root/exit-join-token.txt)"
```

---

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| Client connects but no internet | `wg show wg1` on the middle: is there a handshake? `ip route show table 100` must show `default dev wg1` |
| `wg show wg1` has no handshake | `systemctl status waterwall` on both sides, `tail /var/log/waterwall/network.log`, is `tcp/443` open on the VPS (cloud firewall too)? |
| Handshake works but traffic dies quickly | MTU: keep client MTU at 1280 (`default_mtu`); check MSS clamping rules with `iptables -t mangle -S` |
| Exit shows no packets leaving | `iptables -t nat -L POSTROUTING -n -v` on the VPS, `sysctl net.ipv4.ip_forward` must be `1` |
| Dashboard unreachable from LAN | in the container: `systemctl status wireguard-dashboard`, `ss -lntp \| grep 8080` |
| Dashboard HTTPS fails | domain must point to your home IP, `tcp/80` forwarded, `certbot --nginx -d <domain>` again inside the container |
| Clients cannot connect at all | is `udp/51820` forwarded to the LXC, is `<LXC-IP>:51820` reachable from the LAN (`wg show wg0` lists the port), did your public IP change? |
| Container has no internet | `pct exec <id> -- ping -c1 1.1.1.1`, check `--nameserver`/gateway on the Proxmox side |
| `waterwall` exits immediately | `journalctl -u waterwall -n 40`: either the tunnel port is already used (nginx/caddy/xray on 443) or a WaterWall release renamed a node setting |

WaterWall is downloaded from its [releases](https://github.com/radkesvat/WaterWall/releases).
If a future release renames node settings the tunnel may refuse to start; pin a
known-good version with `--version v1.5.42` (both installers accept it).

---

## 7. Internals (for when you want to change something)

Everything the installers generate:

| Path | Role |
|---|---|
| `/etc/waterwall/core.json` | WaterWall core settings (workers, logs, which tunnel file to load) |
| `/etc/waterwall/middle.json` / `exit.json` | the tunnel chain for that side |
| `/etc/waterwall/instance.env` | the state file (mode, ports, secrets, keys) — mode `600` |
| `/etc/waterwall/certs/` | TLS certificate used by `halfduplex`/`split` |
| `/etc/wireguard/wg0.conf` | middle: clients · exit: the tunnel server (loopback only) |
| `/etc/wireguard/wg1.conf` | middle only: WireGuard client towards the exit |
| `/usr/local/bin/wgmw-routes` | middle policy routing (`wg0` → `wg1`, MSS clamp) |
| `/usr/local/bin/ww-firewall` | exit firewall/NAT (idempotent, `up`/`down`) |
| `/usr/local/bin/ww-health` + `ww-health.timer` | middle tunnel watchdog |
| `/opt/waterwall/Waterwall` | the WaterWall core binary |
| `/opt/wireguard-dashboard` | the dashboard (installed by its own installer) |

Address plan (change it in the scripts if it collides with your LAN):

| Network | Use |
|---|---|
| `10.8.0.0/24` | WireGuard clients (`10.8.0.1` = middle) |
| `10.9.0.0/24` | middle ↔ exit WireGuard link (`10.9.0.1` = exit, `10.9.0.2` = middle) |
| `127.0.0.1:51821/udp` | middle: WaterWall listens here, `wg1` uses it as its endpoint |
| `127.0.0.1:51820/udp` | exit: WireGuard server, reachable only through the tunnel |

Why it works without NAT on the middle: the exit's peer allows
`10.8.0.0/24` *and* `10.9.0.2/32`, so client packets keep their `10.8.0.x`
source address across the tunnel; the exit is the only place that does
masquerading. That is why the exit sees real per-client addresses.

Routing on the middle:

```
ip rule  to 10.8.0.0/24 lookup main   pref 99    # client <-> client stays local
ip rule  iif wg0        lookup 100    pref 100   # everything else goes to the tunnel
ip route default dev wg1 table 100
```

Repo layout:

```
install-exit.sh              one-liner bootstrap for the VPS
install-middle.sh            one-liner bootstrap for the Proxmox host
scripts/lib/common.sh        logging, tokens, validation
scripts/lib/waterwall.sh     WaterWall install + tunnel profile generator (both sides)
scripts/exit/install.sh      exit VPS installer
scripts/middle/install.sh    Proxmox host installer (creates the LXC)
scripts/middle/container-install.sh   in-container installer (dashboard, WG, WaterWall)
scripts/middle/middle-routes.sh       policy routing helper
```

---

## 8. Security notes

* The **join token** contains the middle's WireGuard private key (that is what
  makes the deployment two commands). Treat it like a password, and delete
  `/root/exit-join-token.txt` when you are done. Prefer `--manual-keys` on the
  exit if you would rather paste the middle's public key yourself.
* `instance.env` files store keys and the Reality password (`0600`, root only).
* The dashboard is a root-level admin panel: keep it on your LAN or behind
  HTTPS, never on plain HTTP exposed to the internet.
* Reality/`halfduplex` protect the *shape* of the traffic. The payload is
  protected by WireGuard end-to-end between your client and the exit, so a
  broken TLS verification on the tunnel (`verify=false`, self-signed) does not
  expose your traffic.
* `/etc/wireguard/wg0.conf` on the exit is bound to `0.0.0.0` by WireGuard
  itself, therefore the installer adds an input rule that drops `udp/51820`
  from anywhere but `lo`.
