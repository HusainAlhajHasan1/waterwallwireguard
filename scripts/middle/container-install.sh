#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# container-install.sh - runs INSIDE the middle LXC container.
#
# Installs and wires together:
#   wg0   WireGuard server for the clients (dashboard manages its peers)
#   wg1   WireGuard client towards the exit server (endpoint 127.0.0.1)
#   ww    WaterWall, which carries the wg1 UDP packets over the tunnel
#   dash  WireGuard Dashboard (web UI / CLI / Telegram bot)
#
# Traffic flow:
#   client --wg0--> [policy routing, table 100] --wg1--> 127.0.0.1:<51821>
#        --WaterWall--> exit VPS --wg0--> internet
#
# It is idempotent; the Proxmox host installer calls it again on re-installs.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# In the container everything lives in /root/ww-setup (lib/ beside the script);
# when run straight from the repository the library is one directory up.
LIB_DIR=""
for _cand in "$SELF_DIR/lib" "$SELF_DIR/../lib"; do
    if [[ -f "$_cand/common.sh" ]]; then LIB_DIR="$(cd "$_cand" && pwd)"; break; fi
done
[[ -n "$LIB_DIR" ]] || { echo "cannot find lib/common.sh next to $SELF_DIR" >&2; exit 1; }
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/waterwall.sh
source "$LIB_DIR/waterwall.sh"

WG_CLIENT_NET="10.8.0.0/24"
WG_CLIENT_SERVER_IP="10.8.0.1"
WG_TUN_NET="10.9.0.0/24"
MIDDLE_TUN_IP="10.9.0.2"
ROUTING_TABLE=100
MSS=1240

WG_PORT="51820"           # clients connect here (udp)
LOCAL_UDP_PORT="51821"    # WaterWall listens here on 127.0.0.1
PUBLIC_HOST=""
DASH_DOMAIN=""
DASH_EMAIL=""
DASH_USER="admin"
DASH_PASS=""
TG_TOKEN=""
TG_ADMIN=""
JOIN="${WW_JOIN:-}"

usage() {
    cat <<EOF
container-install.sh - middle LXC installer (called by install-middle.sh)

  --join TOKEN          join token from install-exit.sh (or WW_JOIN)
  --wg-port PORT        UDP port clients connect to (default $WG_PORT)
  --public-host HOST    public IP/DDNS name written into client configs
  --dash-domain DOMAIN  serve the dashboard over HTTPS with this domain
  --dash-email EMAIL    Let's Encrypt contact address
  --admin-user USER     dashboard admin username
  --admin-pass PASS     dashboard admin password
  --telegram-token T    optional Telegram bot token
  --telegram-admin ID   optional Telegram admin chat id
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --join)           JOIN="$2"; shift 2 ;;
        --wg-port)        WG_PORT="$2"; shift 2 ;;
        --public-host)    PUBLIC_HOST="$2"; shift 2 ;;
        --dash-domain)    DASH_DOMAIN="$2"; shift 2 ;;
        --dash-email)     DASH_EMAIL="$2"; shift 2 ;;
        --admin-user)     DASH_USER="$2"; shift 2 ;;
        --admin-pass)     DASH_PASS="$2"; shift 2 ;;
        --telegram-token) TG_TOKEN="$2"; shift 2 ;;
        --telegram-admin) TG_ADMIN="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "Unknown option: $1" ;;
    esac
done

need_root
[[ -n "$JOIN" ]] || die "Missing --join token (or WW_JOIN)."
token_parse "$JOIN" || die "The join token could not be decoded."
token_to_state
: "${MODE:?}"; : "${EXIT_HOST:?}"; : "${PORT:?}"
is_port "$WG_PORT" || die "Invalid --wg-port."

# `pct exec` can hand us a minimal environment; make sure the usual sbin/local
# directories are searched (wgdash, wg, nginx helpers live there). Appended, so
# anything already on PATH keeps its precedence.
case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ;;
esac
export PATH
[[ -n "$DASH_PASS" ]] || DASH_PASS="$(rand_str 16)"

TUNNEL_PORTS="$PORT"
MODE_TARGET="$EXIT_HOST:$PORT"
if [[ "$MODE" == split ]]; then
    TUNNEL_PORTS="$PORT $PORT2"
    MODE_TARGET="$EXIT_HOST:$PORT/$PORT2"
fi

banner "Middle server: installing inside the container"
info "Tunnel mode : $MODE -> $MODE_TARGET"
info "Clients     : udp/$WG_PORT"

mkdir -p "$WW_ETC" "$WW_VAR" "$WW_LOG"
chmod 700 "$WW_ETC" "$WW_VAR"

wait_for_network

# -------------------------------------------------------------- packages ---
log "Installing packages"
PKGS=(curl ca-certificates unzip openssl wireguard-tools iptables iproute2 procps
      python3 python3-venv python3-pip git rsync)
if [[ -n "$DASH_DOMAIN" ]]; then PKGS+=(nginx certbot python3-certbot-nginx); fi
apt_install "${PKGS[@]}"

# ---------------------------------------------------------------- sysctl ---
log "Enabling IP forwarding"
if ! sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
    warn "Cannot enable net.ipv4.ip_forward inside this container."
    hint "Fix on the Proxmox host: append 'lxc.mount.auto: proc:rw sys:rw' to"
    hint "/etc/pve/lxc/<id>.conf, restart the container and run the installer again."
else
    ok "IP forwarding enabled"
fi
sysctl_write /etc/sysctl.d/99-waterwall-middle.conf \
    "net.ipv4.ip_forward=1" \
    "net.ipv4.conf.all.rp_filter=2" \
    "net.ipv4.conf.default.rp_filter=2" \
    "net.core.default_qdisc=fq" \
    "net.ipv4.tcp_congestion_control=bbr"

# ------------------------------------------------------------ routing sh ---
log "Installing the policy routing helper"
install -m 0755 "$SELF_DIR/middle-routes.sh" /usr/local/bin/wgmw-routes
install -m 0755 "$SELF_DIR/wgmw-doctor.sh" /usr/local/bin/wgmw-doctor

cat > /etc/systemd/system/wgmw-routing.service <<'EOF'
[Unit]
Description=WireGuard middle server routing (wg0 clients -> wg1 tunnel)
After=network-online.target wg-quick@wg0.service wg-quick@wg1.service
Wants=network-online.target wg-quick@wg0.service wg-quick@wg1.service
Before=wireguard-dashboard.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/wgmw-routes up
ExecStop=/usr/local/bin/wgmw-routes down

[Install]
WantedBy=multi-user.target
EOF

# Re-apply the routing whenever the tunnel interface is restarted.
mkdir -p /etc/systemd/system/wg-quick@wg1.service.d
cat > /etc/systemd/system/wg-quick@wg1.service.d/routing.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/bin/wgmw-routes up
EOF

# ------------------------------------------------------------- WireGuard ---
log "Writing the WireGuard configuration"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

WG0_PRIV="$(kv_get "$WW_STATE_FILE" WG0_PRIV)"
WG1_PRIV="$(kv_get "$WW_STATE_FILE" WG1_PRIV)"

if [[ -z "$WG0_PRIV" ]]; then
    WG0_PRIV="$(wg genkey)"
    ok "Generated the client-facing server keypair"
fi
WG0_PUB="$(printf '%s' "$WG0_PRIV" | wg pubkey)"

if [[ -n "${MID_WG_PRIV:-}" ]]; then
    WG1_PRIV="$MID_WG_PRIV"
elif [[ -z "$WG1_PRIV" ]]; then
    warn "The join token did not carry a middle key - generating a new one."
    WG1_PRIV="$(wg genkey)"
    MID_WG_NEEDS_AUTH=1
fi
WG1_PUB="$(printf '%s' "$WG1_PRIV" | wg pubkey)"

# The dashboard reads the server key from these files (Server -> rotate keys).
umask 077
printf '%s\n' "$WG0_PRIV" > /etc/wireguard/privatekey
printf '%s\n' "$WG0_PUB"  > /etc/wireguard/publickey
umask 022

if [[ -f /etc/wireguard/wg0.conf ]] && ! grep -q 'waterwallwireguard' /etc/wireguard/wg0.conf; then
    cp -a /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.unrelated-$(date +%Y%m%d-%H%M%S).bak"
    warn "An unrelated wg0.conf was backed up."
fi

if [[ ! -f /etc/wireguard/wg0.conf ]] || ! grep -q 'waterwallwireguard' /etc/wireguard/wg0.conf; then
    cat > /etc/wireguard/wg0.conf <<EOF
# managed by waterwallwireguard - client facing interface
[Interface]
PrivateKey = $WG0_PRIV
Address = $WG_CLIENT_SERVER_IP/24
MTU = 1280
ListenPort = $WG_PORT
SaveConfig = false
PostUp = /usr/local/bin/wgmw-routes up
PostDown = /usr/local/bin/wgmw-routes down
EOF
else
    # Keep the existing peers, refresh the managed interface lines.
    python3 - "$WG_PORT" "$WG_CLIENT_SERVER_IP" <<'PY'
import re, sys
port, addr = sys.argv[1], sys.argv[2]
path = "/etc/wireguard/wg0.conf"
text = open(path).read()
head, sep, tail = text.partition("[Peer]")
head = re.sub(r'(?m)^(ListenPort\s*=).*$', r'\1 %s' % port, head)
head = re.sub(r'(?m)^(Address\s*=).*$', r'\1 %s/24' % addr, head)
open(path, "w").write(head + sep + tail if sep else head)
PY
fi
chmod 600 /etc/wireguard/wg0.conf

cat > /etc/wireguard/wg1.conf <<EOF
# managed by waterwallwireguard - tunnel towards the exit server
# The endpoint is WaterWall on loopback: the UDP packets are carried over the
# WaterWall tunnel and leave the exit server.
[Interface]
PrivateKey = $WG1_PRIV
Address = $MIDDLE_TUN_IP/24
MTU = 1280
Table = off
SaveConfig = false
PostUp = /usr/local/bin/wgmw-routes up
PostDown = /usr/local/bin/wgmw-routes down

[Peer]
PublicKey = ${EXIT_WG_PUB:?the join token has no exit WireGuard key}
AllowedIPs = 0.0.0.0/0
Endpoint = 127.0.0.1:$LOCAL_UDP_PORT
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg1.conf

kv_save "$WW_STATE_FILE" \
    "ROLE=middle" \
    "MODE=$MODE" \
    "EXIT_HOST=$EXIT_HOST" \
    "PORT=$PORT" \
    "PORT2=${PORT2:-}" \
    "SNI=${SNI:-}" \
    "COVER=${COVER:-}" \
    "COVER_PORT=${COVER_PORT:-443}" \
    "SECRET=${SECRET:-}" \
    "TLS_VERIFY=${TLS_VERIFY:-false}" \
    "EXIT_WG_PUB=${EXIT_WG_PUB:-}" \
    "EXIT_WG_PORT=${EXIT_WG_PORT:-51820}" \
    "WW_VERSION=${WW_VERSION:-}" \
    "ENTRY=${ENTRY:-home}" \
    "ENTRY_PORT=${ENTRY_PORT:-51820}" \
    "RELAY_PORT=${RELAY_PORT:-7000}" \
    "WG_PORT=$WG_PORT" \
    "LOCAL_UDP_PORT=$LOCAL_UDP_PORT" \
    "WG0_PRIV=$WG0_PRIV" \
    "WG0_PUB=$WG0_PUB" \
    "WG1_PRIV=$WG1_PRIV" \
    "WG1_PUB=$WG1_PUB" \
    "PUBLIC_HOST=${PUBLIC_HOST:-}"

printf '%s\n' "$WG1_PUB" > /etc/waterwall/middle-pubkey.txt 2>/dev/null || {
    mkdir -p /etc/waterwall; printf '%s\n' "$WG1_PUB" > /etc/waterwall/middle-pubkey.txt; }

# ------------------------------------------------------------ WaterWall ----
# Use the exact WaterWall build the exit reported, so the two sides cannot
# drift apart on a protocol change.
if [[ -n "${WW_VERSION:-}" && "${WW_VERSION}" != "latest" ]]; then
    if [[ "${WATERWALL_VERSION:-latest}" == "latest" ]]; then
        export WATERWALL_VERSION="$WW_VERSION"
    fi
    info "WaterWall build from the join token: ${WW_VERSION} (installing: $WATERWALL_VERSION)"
fi
ww_install_binary
[[ -n "${WW_INSTALLED_VERSION:-}" ]] && WW_VERSION="$WW_INSTALLED_VERSION"

export WW_ROLE=middle WW_MODE="$MODE" WW_PORT="$PORT" WW_PORT2="${PORT2:-}"
export WW_EXIT_HOST="$EXIT_HOST" WW_SNI="${SNI:-}" WW_COVER="${COVER:-}" WW_COVER_PORT="${COVER_PORT:-443}"
export WW_SECRET="${SECRET:-}" WW_TLS_VERIFY="${TLS_VERIFY:-false}"
export WW_LOCAL_UDP_PORT="$LOCAL_UDP_PORT"
export WW_WORKERS="$(nproc 2>/dev/null || echo 1)"
export WW_RAM_PROFILE="client"

log "Rendering the WaterWall configuration"
mkdir -p "$WW_ETC" "$WW_LOG" "$WW_VAR"
chmod 700 "$WW_ETC" "$WW_VAR"
ww_write_core
ww_write_config middle
ww_write_systemd

systemctl enable wg-quick@wg1.service >/dev/null 2>&1 || true
systemctl enable wg-quick@wg0.service >/dev/null 2>&1 || true
systemctl enable wgmw-routing.service >/dev/null 2>&1 || true
systemctl daemon-reload

ww_apply

log "Starting WireGuard interfaces"
systemctl restart wg-quick@wg1.service
if ! wg show wg1 >/dev/null 2>&1; then
    service_dump wg-quick@wg1.service
    die "The tunnel interface wg1 did not come up."
fi
systemctl restart wg-quick@wg0.service
if ! wg show wg0 >/dev/null 2>&1; then
    service_dump wg-quick@wg0.service
    die "The client interface wg0 did not come up."
fi
systemctl restart wgmw-routing.service
ok "wg0 (clients, udp/$WG_PORT) and wg1 (tunnel) are up"

# ------------------------------------------------------------------ relay ---
# When the exit accepts the clients (the home line cannot), this container
# keeps an outbound connection to it and feeds wg0 through it - no inbound
# port on the home side at all.
if [[ "${ENTRY:-home}" == vps ]]; then
    log "Wiring the client entry relay towards $EXIT_HOST:${RELAY_PORT:-7000}"
    install -m 0755 "$SELF_DIR/wgmw-relay.py" /usr/local/bin/wgmw-relay \
        || die "wgmw-relay.py is missing next to this script ($SELF_DIR)."
    RELAY_SECRET_FILE=/etc/waterwall/relay.secret
    mkdir -p /etc/waterwall
    ( umask 077; relay_secret_from "${SECRET:-}" > "$RELAY_SECRET_FILE" )
    cat > /etc/systemd/system/wgmw-relay.service <<UNIT
[Unit]
Description=waterwallwireguard client entry relay
After=network-online.target wg-quick@wg0.service
Wants=network-online.target wg-quick@wg0.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wgmw-relay client --server $EXIT_HOST:${RELAY_PORT:-7000} --target 127.0.0.1:$WG_PORT --secret-file $RELAY_SECRET_FILE
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable wgmw-relay.service >/dev/null 2>&1 || true
    systemctl restart wgmw-relay.service
    sleep 2
    if systemctl is-active --quiet wgmw-relay.service; then
        ok "relay connected to $EXIT_HOST - clients reach wg0 through it"
    else
        service_dump wgmw-relay.service
        warn "The relay did not come up - clients will not reach this container."
    fi
else
    systemctl disable --now wgmw-relay.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wgmw-relay.service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------- dashboard ---
export WGDASH_DIR=/opt/wireguard-dashboard
export WGDASH_SRC=/opt/wgdash-src
DASH_BIND="0.0.0.0"
DASH_URL_SCHEME="http"

if [[ -n "$DASH_DOMAIN" ]]; then
    log "Configuring HTTPS for the dashboard ($DASH_DOMAIN)"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/log/nginx
    cat > /etc/nginx/sites-available/wgdash <<NGINX
server {
    listen 80;
    server_name $DASH_DOMAIN;

    access_log /var/log/nginx/wgdash.access.log;
    error_log  /var/log/nginx/wgdash.error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/wgdash /etc/nginx/sites-enabled/wgdash
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || systemctl restart nginx
    if certbot --nginx --non-interactive --agree-tos --keep-until-expiring \
            --redirect -m "$DASH_EMAIL" -d "$DASH_DOMAIN" >/tmp/certbot-nginx.log 2>&1; then
        DASH_BIND="127.0.0.1"
        DASH_URL_SCHEME="https"
        ok "HTTPS ready: https://$DASH_DOMAIN"
    else
        warn "Let's Encrypt failed for $DASH_DOMAIN (see /tmp/certbot-nginx.log)."
        hint "The dashboard stays available on http://<container-ip>:8080."
        rm -f /etc/nginx/sites-enabled/wgdash
        systemctl reload nginx 2>/dev/null || true
    fi
fi

# An endpoint is host:port, and an IPv6 literal has to be bracketed:
# [2001:db8::1234]:51820 . Hostnames and IPv4 are used as they are.
endpoint_of() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\]* ]]; then
        host="[$host]"
    fi
    printf '%s:%s' "$host" "$port"
}

if [[ "${ENTRY:-home}" == vps ]]; then
    ENDPOINT="$(endpoint_of "$EXIT_HOST" "${ENTRY_PORT:-51820}")"
elif [[ -n "$PUBLIC_HOST" ]]; then
    ENDPOINT="$(endpoint_of "$PUBLIC_HOST" "$WG_PORT")"
else
    DETECTED="$(detect_public_ipv4 || true)"
    ENDPOINT="$(endpoint_of "${DETECTED:-127.0.0.1}" "$WG_PORT")"
    if [[ -z "$DETECTED" ]]; then
        warn "Could not detect your public IPv4 - set it later in the dashboard (Server -> endpoint)."
    fi
fi
case "$ENDPOINT" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
        warn "Your public IP looks like carrier-grade NAT (100.64.0.0/10)."
        hint "Port forwarding will NOT work until your ISP gives you a real public IPv4."
        ;;
esac

if [[ -f /etc/wireguard-dashboard/config.json ]] && \
   { [[ -x /usr/local/bin/wgdash ]] || command -v wgdash >/dev/null 2>&1; }; then
    ok "WireGuard Dashboard already installed - refreshing its settings"
else
    log "Installing the WireGuard Dashboard"
    if [[ -d "$WGDASH_SRC/.git" ]]; then
        git -C "$WGDASH_SRC" fetch --depth 1 origin "$WGDASH_REF" >/dev/null 2>&1 \
            && git -C "$WGDASH_SRC" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
    else
        rm -rf "$WGDASH_SRC"
        git clone --depth 1 --branch "$WGDASH_REF" "https://github.com/$WGDASH_REPO.git" "$WGDASH_SRC" \
            || die "Could not clone https://github.com/$WGDASH_REPO"
    fi
    DASH_ARGS=(--unattended --no-caddy
               --admin-user "$DASH_USER" --admin-pass "$DASH_PASS"
               --bind "$DASH_BIND" --port 8080
               --endpoint "$ENDPOINT"
               --wg-interface wg0)
    [[ -n "$TG_TOKEN" ]] && DASH_ARGS+=(--telegram-token "$TG_TOKEN")
    [[ -n "$TG_ADMIN" ]] && DASH_ARGS+=(--telegram-admin "$TG_ADMIN")
    ( cd "$WGDASH_SRC" && bash install.sh "${DASH_ARGS[@]}" ) || die "The dashboard installer failed."
fi

# Dashboard defaults tuned for this topology (MTU 1280, IPv4 full tunnel).
#
# Resolve the CLI explicitly instead of trusting PATH: `pct exec` can hand the
# script a minimal environment, and the wrapper lives in /usr/local/bin.
log "Applying dashboard defaults"
dash_works() { "$@" --help >/dev/null 2>&1; }
WGDASH_CMD=()
if [[ -x /usr/local/bin/wgdash ]] && dash_works /usr/local/bin/wgdash; then
    WGDASH_CMD=(/usr/local/bin/wgdash)
else
    cand="$(command -v wgdash 2>/dev/null || true)"
    if [[ -n "$cand" ]] && dash_works "$cand"; then
        WGDASH_CMD=("$cand")
    elif [[ -x "$WGDASH_DIR/venv/bin/python" ]] && dash_works "$WGDASH_DIR/venv/bin/python" \
            -m wgdash.cli --config /etc/wireguard-dashboard/config.json; then
        WGDASH_CMD=("$WGDASH_DIR/venv/bin/python" -m wgdash.cli
                    --config /etc/wireguard-dashboard/config.json)
    fi
fi
if [[ ${#WGDASH_CMD[@]} -eq 0 ]]; then
    warn "The dashboard CLI was not found - skipping its default settings."
    hint "Run later inside the container:"
    hint "  wgdash set-setting default_mtu 1280"
    hint "  wgdash set-setting default_allowed_ips '\"0.0.0.0/0\"'"
    hint "  wgdash set-setting default_dns '\"1.1.1.1, 8.8.8.8\"'"
    hint "  wgdash set-setting default_keepalive 25"
    hint "  wgdash set-setting endpoint $ENDPOINT"
else
    info "dashboard CLI: ${WGDASH_CMD[0]}"
    DASH_SET_FAILED=0
    "${WGDASH_CMD[@]}" set-setting endpoint "$ENDPOINT" >/dev/null 2>&1 || DASH_SET_FAILED=1
    "${WGDASH_CMD[@]}" set-setting default_mtu 1280 >/dev/null 2>&1 || DASH_SET_FAILED=1
    "${WGDASH_CMD[@]}" set-setting default_allowed_ips '"0.0.0.0/0"' >/dev/null 2>&1 || DASH_SET_FAILED=1
    "${WGDASH_CMD[@]}" set-setting default_dns '"1.1.1.1, 8.8.8.8"' >/dev/null 2>&1 || DASH_SET_FAILED=1
    "${WGDASH_CMD[@]}" set-setting default_keepalive 25 >/dev/null 2>&1 || DASH_SET_FAILED=1
    if [[ $DASH_SET_FAILED -eq 0 ]]; then
        ok "dashboard defaults: MTU 1280, 0.0.0.0/0, DNS 1.1.1.1+8.8.8.8, keepalive 25"
    else
        warn "Some dashboard defaults could not be set - check Settings in the panel."
        hint "PATH=$PATH"
    fi
fi

# public_url drives cookie security and the share links
if [[ "$DASH_URL_SCHEME" == https ]]; then
    python3 - "$DASH_DOMAIN" <<'PY'
import json, sys, pathlib
path = pathlib.Path("/etc/wireguard-dashboard/config.json")
cfg = json.loads(path.read_text())
cfg["public_url"] = "https://%s" % sys.argv[1]
cfg["listen_host"] = "127.0.0.1"
path.write_text(json.dumps(cfg, indent=2))
PY
else
    python3 - <<'PY'
import json, pathlib
path = pathlib.Path("/etc/wireguard-dashboard/config.json")
cfg = json.loads(path.read_text())
cfg["public_url"] = ""
cfg["listen_host"] = "0.0.0.0"
path.write_text(json.dumps(cfg, indent=2))
PY
fi

systemctl enable wireguard-dashboard.service >/dev/null 2>&1 || true
systemctl restart wireguard-dashboard.service
if ! wait_service wireguard-dashboard.service 20; then
    service_dump wireguard-dashboard.service
    die "wireguard-dashboard.service failed to start."
fi
ok "dashboard service running"

# ---------------------------------------------------------- health timer ---
log "Installing the tunnel health check (restarts WaterWall if the tunnel dies)"
cat > /usr/local/bin/ww-health <<'HEALTH'
#!/usr/bin/env bash
# Restarts WaterWall when the tunnel WireGuard handshake has been stale for too
# long. PersistentKeepalive keeps a healthy tunnel's handshake fresh, so a stale
# handshake really means the tunnel is broken.
set -u
STALE="${STALE_SECONDS:-300}"
STATE=/var/lib/waterwall/health.state
IFACE="${TUNNEL_IFACE:-wg1}"
systemctl is-active --quiet waterwall.service || exit 0
hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
[[ -z "$hs" || "$hs" == "0" ]] && exit 0
now=$(date +%s)
age=$(( now - hs ))
[[ $age -lt $STALE ]] && exit 0
last=$(cat "$STATE" 2>/dev/null || echo 0)
[[ "$last" =~ ^[0-9]+$ ]] || last=0
if [[ $(( now - last )) -lt 300 ]]; then exit 0; fi
printf '%s\n' "$now" > "$STATE"
logger -t ww-health "tunnel handshake is ${age}s old - restarting waterwall.service"
systemctl restart waterwall.service
HEALTH
chmod 755 /usr/local/bin/ww-health

cat > /etc/systemd/system/ww-health.service <<'EOF'
[Unit]
Description=WaterWall tunnel health check
After=waterwall.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ww-health
EOF
cat > /etc/systemd/system/ww-health.timer <<'EOF'
[Unit]
Description=Run the WaterWall tunnel health check every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now ww-health.timer >/dev/null 2>&1 || warn "Could not enable ww-health.timer"

# --------------------------------------------------------------- summary ---
CT_ADDR="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
DASH_URL="http://${CT_ADDR:-<container-ip>}:8080"
[[ "$DASH_URL_SCHEME" == https ]] && DASH_URL="https://$DASH_DOMAIN"

banner "Middle container is ready"
cat <<EOF
  Tunnel          : $MODE -> $MODE_TARGET
  wg0 (clients)   : $WG_CLIENT_SERVER_IP/24, udp/$WG_PORT, MTU 1280
  wg1 (tunnel)    : $MIDDLE_TUN_IP/24 -> 127.0.0.1:$LOCAL_UDP_PORT (WaterWall)
  Middle pubkey   : $WG1_PUB
  Dashboard       : $DASH_URL   ($DASH_USER / $DASH_PASS)

  Check the tunnel:  wg show wg1 latest-handshakes ; wg show wg1 transfer
  Tunnel logs     :  journalctl -u waterwall -f   |   $WW_LOG/network.log
EOF

if [[ "${MID_WG_NEEDS_AUTH:-0}" == "1" || -z "${MID_WG_PRIV:-}" ]]; then
    cat <<EOF

${C_YELLOW}ACTION NEEDED${C_RESET}: the exit server does not know this middle's WireGuard key.
On the exit VPS run:

  bash install-exit.sh --middle-pubkey $WG1_PUB
EOF
fi
