#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# middle-routes.sh - installed as /usr/local/bin/wgmw-routes in the middle LXC.
#
# Sends everything that arrives from a WireGuard client (wg0) into the
# WaterWall tunnel interface (wg1) through a dedicated routing table, so the
# container's own traffic keeps using the normal default route of the LAN.
#
#   wgmw-routes up    (PostUp of wg0 and wg1, and wgmw-routing.service)
#   wgmw-routes down  (PostDown)
#
# Everything here is idempotent: running it twice is harmless.
# ---------------------------------------------------------------------------
set -u

ACTION="${1:-up}"
WG_IN="${WG_IN:-wg0}"                  # client facing interface
WG_OUT="${WG_OUT:-wg1}"                # tunnel towards the exit server
TABLE="${TABLE:-100}"                  # routing table for client traffic
MSS="${MSS:-1240}"                     # 1280 (tunnel MTU) - 40
CLIENT_NET="${CLIENT_NET:-10.8.0.0/24}"

HAVE_IPTABLES=1
command -v iptables >/dev/null 2>&1 || HAVE_IPTABLES=0

ipt()        { iptables "$@" 2>/dev/null; }
ipt_ensure() { local t="$1" c="$2"; shift 2
               [[ $HAVE_IPTABLES -eq 1 ]] || return 0
               ipt -t "$t" -C "$c" "$@" || ipt -t "$t" -A "$c" "$@"; return 0; }
ipt_remove() { local t="$1" c="$2"; shift 2
               [[ $HAVE_IPTABLES -eq 1 ]] || return 0
               ipt -t "$t" -D "$c" "$@" || true; return 0; }

sysctl_soft() { sysctl -qw "$1" >/dev/null 2>&1 || true; }

wait_dev() {   # wait_dev <interface> - up to 10s
    local i
    for i in {1..20}; do
        ip link show "$1" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

rules_del() {
    while ip rule show | grep -q "iif $WG_IN lookup $TABLE"; do
        ip rule del iif "$WG_IN" lookup "$TABLE" 2>/dev/null || break
    done
    while ip rule show | grep -q "to $CLIENT_NET lookup main"; do
        ip rule del to "$CLIENT_NET" lookup main 2>/dev/null || break
    done
}

rules_add() {
    rules_del
    # client -> client traffic never leaves the server
    ip rule add to "$CLIENT_NET" lookup main pref 99 2>/dev/null || true
    # everything else that comes from a client uses the tunnel table
    ip rule add iif "$WG_IN" lookup "$TABLE" pref 100 2>/dev/null || true
}

up() {
    sysctl_soft net.ipv4.ip_forward=1
    sysctl_soft net.ipv4.conf.all.rp_filter=2
    sysctl_soft net.ipv4.conf.default.rp_filter=2
    sysctl_soft "net.ipv4.conf.$WG_OUT.rp_filter=2"

    # forwarding between clients and the tunnel
    ipt_ensure filter FORWARD -i "$WG_IN" -o "$WG_OUT" -j ACCEPT
    ipt_ensure filter FORWARD -i "$WG_OUT" -o "$WG_IN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # keep TCP segments below the tunnel MTU in both directions
    ipt_ensure mangle FORWARD -i "$WG_IN" -o "$WG_OUT" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
    ipt_ensure mangle FORWARD -i "$WG_OUT" -o "$WG_IN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"

    if wait_dev "$WG_IN"; then
        rules_add
    else
        echo "wgmw-routes: $WG_IN is missing" >&2
    fi

    if wait_dev "$WG_OUT"; then
        ip route replace default dev "$WG_OUT" table "$TABLE"
    else
        echo "wgmw-routes: $WG_OUT is missing (is the WaterWall tunnel up?)" >&2
    fi
    exit 0
}

down() {
    rules_del
    ip route flush table "$TABLE" 2>/dev/null || true
    ipt_remove mangle FORWARD -i "$WG_OUT" -o "$WG_IN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
    ipt_remove mangle FORWARD -i "$WG_IN" -o "$WG_OUT" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
    ipt_remove filter FORWARD -i "$WG_OUT" -o "$WG_IN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ipt_remove filter FORWARD -i "$WG_IN" -o "$WG_OUT" -j ACCEPT
    exit 0
}

case "$ACTION" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: wgmw-routes up|down" >&2; exit 1 ;;
esac
