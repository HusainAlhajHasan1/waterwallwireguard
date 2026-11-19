#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wgmw-doctor.sh - installed as /usr/local/bin/wgmw-doctor in the middle LXC.
#
# Answers one question: "a client cannot connect - where is it stuck?"
# It walks the chain client -> router -> wg0 -> wg1 -> WaterWall -> exit and
# prints what it finds. Read-only, safe to run any time.
# ---------------------------------------------------------------------------
set -u

WG_IN="${WG_IN:-wg0}"
WG_OUT="${WG_OUT:-wg1}"
WG_PORT="${WG_PORT:-51820}"
TUNNEL_PORT="${TUNNEL_PORT:-443}"
TABLE="${TABLE:-100}"
CONF=/etc/wireguard-dashboard/config.json

hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { printf '   \033[32mok\033[0m    %s\n' "$*"; }
bad() { printf '   \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33mwarn\033[0m  %s\n' "$*"; }
say() { printf '         %s\n' "$*"; }
indent() { sed 's/^/         /'; }

# --------------------------------------------------------------- addresses ---
hdr "container"
CT_IP="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
GW_IP="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
say "address : ${CT_IP:-unknown}   gateway: ${GW_IP:-unknown}"
systemctl is-active --quiet waterwall.service && ok "waterwall.service is running" \
    || bad "waterwall.service is not running (journalctl -u waterwall -n 40)"

# ---------------------------------------------------------------- listeners ---
hdr "client socket"
if ss -lunp 2>/dev/null | grep -q ":$WG_PORT "; then
    ok "udp/$WG_PORT is listening"
else
    bad "nothing is listening on udp/$WG_PORT (wg-quick@$WG_IN up?)"
fi

# --------------------------------------------------------------- wg0 clients ---
hdr "$WG_IN (clients)"
if ! wg show "$WG_IN" >/dev/null 2>&1; then
    bad "$WG_IN does not exist - systemctl status wg-quick@$WG_IN"
else
    wg show "$WG_IN" | indent
    PEERS="$(wg show "$WG_IN" peers 2>/dev/null | grep -c . || true)"
    LIVE="$(wg show "$WG_IN" latest-handshakes 2>/dev/null | awk 'NF > 1 && $2 > 0' | grep -c . || true)"
    PEERS="${PEERS:-0}"; LIVE="${LIVE:-0}"
    say ""
    say "peers: $PEERS, with a handshake: $LIVE"
    if [[ $PEERS -eq 0 ]]; then
        bad "no peer configured - add one in the dashboard (Peers -> Add peer)"
    elif [[ $LIVE -eq 0 ]]; then
        bad "no client ever completed a handshake => client packets never arrive"
        say "  1. is your router forwarding UDP $WG_PORT to $CT_IP:$WG_PORT ?"
        say "  2. does the client config point at your CURRENT public IP? (see below)"
        say "  3. NAT loopback: a phone on your home Wi-Fi cannot reach your own"
        say "     public IP through most routers - test with mobile data instead"
        say "  4. watch for packets while the client tries (inside the container):"
        say "     tcpdump -ni any udp port $WG_PORT"
        say "  5. to test the router forward alone, send one packet from outside"
        say "     (e.g. from the exit VPS) and look for it with the command above:"
    else
        ok "$LIVE peer(s) finished a handshake - the client leg works"
    fi
    SRV_PUB="$(wg show "$WG_IN" public-key 2>/dev/null)"
    say ""
    say "server public key (must match [Peer] PublicKey in the client config):"
    say "  $SRV_PUB"
fi

# --------------------------------------------------------- tunnel to the exit ---
hdr "$WG_OUT (tunnel to the exit)"
if wg show "$WG_OUT" >/dev/null 2>&1; then
    wg show "$WG_OUT" | indent
    HS="$(wg show "$WG_OUT" latest-handshakes 2>/dev/null | awk 'NF > 1 {print $2; exit}')"
    [[ "$HS" =~ ^[0-9]+$ ]] || HS=0
    if [[ "$HS" != "0" ]]; then
        AGE=$(( $(date +%s) - HS ))
        if [[ $AGE -lt 300 ]]; then ok "handshake ${AGE}s old - the tunnel is alive"
        else bad "handshake ${AGE}s old - the tunnel to the exit is down"; fi
    else
        bad "never handshaked with the exit"
        say "check: systemctl status waterwall ; tail -n 40 /var/log/waterwall/network.log"
        say "on the exit: systemctl status waterwall ; and tcp/$TUNNEL_PORT open?"
    fi
else
    bad "$WG_OUT does not exist - systemctl status wg-quick@$WG_OUT"
fi

# ------------------------------------------------------------------ routing ---
hdr "routing (client -> tunnel)"
ip rule show 2>/dev/null | indent
ROUTE="$(ip route show table "$TABLE" 2>/dev/null)"
printf '%s\n' "${ROUTE:-<empty>}" | indent
if printf '%s' "$ROUTE" | grep -q "default dev $WG_OUT"; then
    ok "table $TABLE sends client traffic into $WG_OUT"
else
    bad "table $TABLE has no default route - run: wgmw-routes up"
fi

# ----------------------------------------------------------- public address ---
hdr "public address"
PUB=""
for svc in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    PUB="$(curl -fsS --max-time 6 "$svc" 2>/dev/null | tr -d '[:space:]')"
    # only accept something that really looks like an address (some services
    # answer with an HTML error page)
    [[ "$PUB" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break || PUB=""
done
EP=""
[[ -f "$CONF" ]] && EP="$(grep -o '"public_endpoint"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null \
    | head -1 | cut -d'"' -f4)"
say "detected now : ${PUB:-unknown}"
say "client config: ${EP:-unknown}"
if [[ -n "$PUB" && -n "$EP" ]]; then
    EP_HOST="${EP%:*}"
    if [[ "$EP_HOST" == "$PUB" ]]; then
        ok "clients are being told the right address"
    else
        warn "clients use $EP_HOST but the world sees $PUB"
        say "fix: dashboard -> Server -> Endpoint, then re-download the client config"
        say "(or re-run the installer with --public-host name.duckdns.org)"
    fi
fi
case "$PUB" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
        bad "that address is carrier-grade NAT (100.64.0.0/10) - port forwarding cannot work"
        ;;
esac
# Same check the other way round: if the router's own WAN address differs from
# what the internet sees, the ISP is translating (CGNAT/DS-Lite) and inbound
# port forwarding cannot work. Compare it on the router's status page.
PUB6="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')"
[[ -n "$PUB6" ]] && say "IPv6 (this host): $PUB6" \
    || say "IPv6 (this host): none - if your ISP only offers DS-Lite, ask about a public IPv4"

printf '\n'
