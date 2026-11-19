#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-exit.sh - sets up the EXIT server (the VPS that client traffic
# leaves from) for a WaterWall + WireGuard middle/exit pair.
#
#   Middle (Proxmox LXC)  --WaterWall tunnel-->  Exit (this VPS)  --> Internet
#
# What it installs here:
#   * WaterWall core + one tunnel profile (halfduplex | split | reality)
#   * a WireGuard server that listens on 127.0.0.1 only (it is reachable
#     exclusively through the tunnel, never from the internet)
#   * NAT/forwarding so traffic leaving the tunnel goes out to the internet
#   * a firewall (tunnel port open, WireGuard port closed to the world)
#
# It is idempotent: re-running keeps the existing secrets and configuration.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SELF_DIR/../lib/common.sh"
# shellcheck source=../lib/waterwall.sh
source "$SELF_DIR/../lib/waterwall.sh"

# ---------------------------------------------------------------- defaults --
WG_CLIENT_NET="10.8.0.0/24"      # subnet used by the WireGuard clients
WG_TUN_NET="10.9.0.0/24"         # subnet of the middle<->exit WireGuard link
EXIT_TUN_IP="10.9.0.1"
MIDDLE_TUN_IP="10.9.0.2"
EXIT_WG_PORT_DEFAULT=51820
SNI_DEFAULT="www.cloudflare.com"

# CLI values (empty = "not given", so the stored value or the default wins)
MODE_CLI=""; PORT_CLI=""; PORT2_CLI=""; SNI_CLI=""; COVER_CLI=""
DOMAIN_CLI=""; EMAIL_CLI=""; EXITHOST_CLI=""; MIDPUB_CLI=""
JOIN="${WW_JOIN:-}"
MANUAL_KEYS=0
SHOW_INFO=0

usage() {
    cat <<EOF
install-exit.sh - EXIT server installer (WaterWall + WireGuard)

Usage:
  bash install-exit.sh [options]

Options:
  --mode MODE             Tunnel mode: halfduplex | split | reality
                          (default: halfduplex)
  --port PORT             Tunnel TCP port on this VPS (default: 443)
  --port2 PORT            Second tunnel TCP port, split mode only (default: 444)
  --sni DOMAIN            SNI / camouflage hostname (default: $SNI_DEFAULT)
                          reality : the real HTTPS site that is imitated
                          tls     : the name on your certificate
  --cover HOST            reality only: site the exit relays probes to
                          (default: same as --sni)
  --tunnel-domain DOMAIN  TLS modes only: use a real Let's Encrypt certificate
                          for this domain (must resolve to this VPS, tcp/80 open)
  --email EMAIL           Let's Encrypt contact address
  --exit-host HOST        Address the middle uses to reach this VPS
                          (default: detected public IPv4)
  --middle-pubkey KEY     Manually authorise the middle WireGuard public key
  --manual-keys           Do not pre-generate the middle keypair (then paste
                          the middle public key here with --middle-pubkey)
  --join TOKEN            Re-apply a previously issued join token (idempotent)
  --info                  Print the current configuration and join token, exit
  --version TAG           Pin a WaterWall release (default: latest)
  -h, --help              This help

Environment: WW_JOIN, WATERWALL_VERSION, WW_REPO, WW_REF
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)          MODE_CLI="$2"; shift 2 ;;
        --port)          PORT_CLI="$2"; shift 2 ;;
        --port2)         PORT2_CLI="$2"; shift 2 ;;
        --sni)           SNI_CLI="$2"; shift 2 ;;
        --cover)         COVER_CLI="$2"; shift 2 ;;
        --tunnel-domain) DOMAIN_CLI="$2"; shift 2 ;;
        --email)         EMAIL_CLI="$2"; shift 2 ;;
        --exit-host)     EXITHOST_CLI="$2"; shift 2 ;;
        --middle-pubkey) MIDPUB_CLI="$2"; shift 2 ;;
        --manual-keys)   MANUAL_KEYS=1; shift ;;
        --join)          JOIN="$2"; shift 2 ;;
        --info)          SHOW_INFO=1; shift ;;
        --version)       WATERWALL_VERSION="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown option: $1 (try --help)" ;;
    esac
done

need_root
[[ -f /etc/os-release ]] || die "Unsupported system (no /etc/os-release)."
have systemctl || die "systemd is required."
have apt-get || die "This installer supports Debian/Ubuntu only."

# ------------------------------------------------------------- load state --
# Precedence: defaults < stored state < join token < command line flags.
if [[ -f "$WW_STATE_FILE" ]]; then
    kv_load "$WW_STATE_FILE"
    HAVE_STATE=1
else
    HAVE_STATE=0
fi
: "${MODE:=halfduplex}"
: "${PORT:=443}"
: "${PORT2:=444}"
: "${SNI:=$SNI_DEFAULT}"
: "${COVER:=$SNI}"
: "${COVER_PORT:=443}"
: "${EXIT_HOST:=$EXITHOST_CLI}"
: "${EXIT_WG_PORT:=$EXIT_WG_PORT_DEFAULT}"
: "${TLS_VERIFY:=false}"
: "${TUNNEL_DOMAIN:=}"
: "${CREATED:=}"
: "${EXT_IF:=}"
: "${SECRET:=}"
: "${EXIT_WG_PRIV:=}"
: "${EXIT_WG_PUB:=}"
: "${MID_WG_PUB:=}"
: "${MID_WG_PRIV:=}"
: "${EMAIL:=}"

if [[ -n "$JOIN" ]]; then
    token_parse "$JOIN" || die "The join token could not be decoded - copy it again, exactly as printed."
    token_to_state
fi

[[ -n "$MODE_CLI" ]]      && MODE="$MODE_CLI"
[[ -n "$PORT_CLI" ]]      && PORT="$PORT_CLI"
[[ -n "$PORT2_CLI" ]]     && PORT2="$PORT2_CLI"
[[ -n "$SNI_CLI" ]]       && SNI="$SNI_CLI"
[[ -n "$COVER_CLI" ]]     && COVER="$COVER_CLI"
[[ -n "$DOMAIN_CLI" ]]    && TUNNEL_DOMAIN="$DOMAIN_CLI"
[[ -n "$EMAIL_CLI" ]]     && EMAIL="$EMAIL_CLI"
[[ -n "$EXITHOST_CLI" ]]  && EXIT_HOST="$EXITHOST_CLI"
[[ -z "$COVER" ]]         && COVER="$SNI"
[[ -z "$CREATED" ]]       && CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$MODE" in
    halfduplex|split|reality) ;;
    *) die "--mode must be one of: $WW_MODES (got: $MODE)" ;;
esac
if [[ "$MODE" == split && -z "$PORT2" ]]; then
    PORT2="$((PORT + 1))"
fi
is_port "$PORT" || die "--port must be a valid port number (got: $PORT)"
if [[ "$MODE" == split ]]; then
    is_port "$PORT2" || die "--port2 must be a valid port number (got: $PORT2)"
    [[ "$PORT" != "$PORT2" ]] || die "--port and --port2 must differ."
fi
is_hostname_or_ip "$SNI" || die "--sni must be a hostname (got: $SNI)"
if [[ "$MODE" == reality ]]; then
    is_hostname_or_ip "$COVER" || die "--cover must be a hostname (got: $COVER)"
elif [[ -n "$TUNNEL_DOMAIN" ]]; then
    is_domain "$TUNNEL_DOMAIN" || die "--tunnel-domain must be a domain name."
    [[ -n "${EMAIL:-}" ]] || EMAIL="admin@$TUNNEL_DOMAIN"
fi

TUNNEL_PORTS="$PORT"
[[ "$MODE" == split ]] && TUNNEL_PORTS="$PORT $PORT2"

# ---------------------------------------------------------------- summary ---
print_summary() {
    banner "Exit server configuration"
    printf '  Tunnel mode      : %s\n' "$MODE"
    printf '  Exit address     : %s\n' "$EXIT_HOST"
    printf '  Tunnel port(s)   : %s/tcp\n' "${TUNNEL_PORTS// /, }"
    if [[ "$MODE" == reality ]]; then
        printf '  Camouflage (SNI) : %s -> %s:%s\n' "$SNI" "$COVER" "$COVER_PORT"
    else
        if [[ -n "$TUNNEL_DOMAIN" ]]; then
            printf '  TLS certificate  : Let'"'"'s Encrypt (%s), verify=%s\n' "$TUNNEL_DOMAIN" "$TLS_VERIFY"
        else
            printf '  TLS certificate  : self-signed, verify=%s\n' "${TLS_VERIFY:-false}"
        fi
    fi
    printf '  WireGuard server : %s (127.0.0.1:%s, never exposed)\n' "$EXIT_TUN_IP" "$EXIT_WG_PORT"
    printf '  Middle public key: %s\n' "${MID_WG_PUB:-<not set yet>}"
    printf '  State file       : %s\n' "$WW_STATE_FILE"
    if [[ "$MODE" != reality ]]; then
        printf '\n  Firewall to allow on this VPS: tcp/%s' "$PORT"
        [[ "$MODE" == split ]] && printf ' and tcp/%s' "$PORT2"
        printf '  (+ tcp/80 while certificates renew)\n'
    else
        printf '\n  Firewall to allow on this VPS: tcp/%s\n' "$PORT"
    fi
    printf '  Health check     : systemctl status waterwall --no-pager ; wg show wg0\n'
}

if [[ $SHOW_INFO -eq 1 ]]; then
    [[ $HAVE_STATE -eq 1 ]] || die "Nothing is installed yet ($WW_STATE_FILE is missing)."
    print_summary
    token_from_state
    printf '\n  Join token: %s\n\n' "$(token_create)"
    exit 0
fi

banner "Exit server installer (WaterWall + WireGuard)"
info "Mode        : $MODE"

wait_for_network

# -------------------------------------------------------------- packages ---
log "Installing required packages"
PKGS=(curl ca-certificates unzip openssl wireguard-tools iptables iproute2 procps python3)
if [[ -n "$TUNNEL_DOMAIN" && "$MODE" != reality ]]; then PKGS+=(certbot); fi
apt_install "${PKGS[@]}"

if [[ -z "$EXIT_HOST" ]]; then
    EXIT_HOST="$(detect_public_ipv4 || true)"
    [[ -n "$EXIT_HOST" ]] || die "Could not detect the public IPv4 of this server. Pass --exit-host."
fi
EXT_IF="${EXT_IF:-$(default_interface)}"
ok "Exit public address: $EXIT_HOST (interface $EXT_IF)"

ww_install_binary

# ------------------------------------------------------------------ keys ---
gen_wg_keypair() {   # sets WG_PRIV / WG_PUB
    WG_PRIV="$(wg genkey)"
    WG_PUB="$(printf '%s' "$WG_PRIV" | wg pubkey)"
}

if [[ -z "$EXIT_WG_PRIV" ]]; then
    log "Generating the exit WireGuard server keypair"
    gen_wg_keypair
    EXIT_WG_PRIV="$WG_PRIV"; EXIT_WG_PUB="$WG_PUB"
else
    EXIT_WG_PUB="$(printf '%s' "$EXIT_WG_PRIV" | wg pubkey)"
fi

if [[ -n "$MIDPUB_CLI" ]]; then
    MID_WG_PUB="$MIDPUB_CLI"
    MID_WG_PRIV=""
elif [[ -z "$MID_WG_PUB" ]]; then
    if [[ $MANUAL_KEYS -eq 0 ]]; then
        log "Generating the middle WireGuard keypair (handed over in the join token)"
        gen_wg_keypair
        MID_WG_PRIV="$WG_PRIV"; MID_WG_PUB="$WG_PUB"
    else
        warn "No middle key yet - add it later with: install-exit.sh --middle-pubkey <KEY>"
    fi
fi
[[ -n "$MID_WG_PUB" ]] && ok "Middle WireGuard public key: $MID_WG_PUB"
[[ -z "$SECRET" ]] && SECRET="$(rand_str 24)"

# ------------------------------------------------------------- state file --
kv_save "$WW_STATE_FILE" \
    "ROLE=exit" \
    "MODE=$MODE" \
    "EXIT_HOST=$EXIT_HOST" \
    "PORT=$PORT" \
    "PORT2=$PORT2" \
    "SNI=$SNI" \
    "COVER=$COVER" \
    "COVER_PORT=$COVER_PORT" \
    "SECRET=$SECRET" \
    "TLS_VERIFY=$TLS_VERIFY" \
    "TUNNEL_DOMAIN=$TUNNEL_DOMAIN" \
    "EXIT_WG_PORT=$EXIT_WG_PORT" \
    "EXIT_WG_PRIV=$EXIT_WG_PRIV" \
    "EXIT_WG_PUB=$EXIT_WG_PUB" \
    "MID_WG_PUB=$MID_WG_PUB" \
    "MID_WG_PRIV=$MID_WG_PRIV" \
    "EXT_IF=$EXT_IF" \
    "CREATED=$CREATED"
ok "state saved to $WW_STATE_FILE"

# ----------------------------------------------------------- certificates --
write_selfsigned() {
    local dir="$WW_ETC/certs"
    mkdir -p "$dir"
    if [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]]; then
        ok "TLS certificate already present in $dir"
        return 0
    fi
    log "Creating a self-signed certificate for SNI $SNI"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
        -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
        || die "openssl could not create the certificate."
    chmod 600 "$dir/privkey.pem"; chmod 644 "$dir/fullchain.pem"
    ok "self-signed certificate written to $dir"
}

if [[ "$MODE" != reality ]]; then
    if [[ -n "$TUNNEL_DOMAIN" ]]; then
        log "Requesting a Let's Encrypt certificate for $TUNNEL_DOMAIN"
        systemctl stop certbot.timer 2>/dev/null || true
        if certbot certonly --standalone --non-interactive --agree-tos \
                --keep-until-expiring -m "$EMAIL" -d "$TUNNEL_DOMAIN" >/tmp/certbot.log 2>&1 \
           && [[ -f "/etc/letsencrypt/live/$TUNNEL_DOMAIN/fullchain.pem" ]]; then
            mkdir -p "$WW_ETC/certs"
            install -m 644 "/etc/letsencrypt/live/$TUNNEL_DOMAIN/fullchain.pem" "$WW_ETC/certs/fullchain.pem"
            install -m 600 "/etc/letsencrypt/live/$TUNNEL_DOMAIN/privkey.pem"  "$WW_ETC/certs/privkey.pem"
            TLS_VERIFY=true
            mkdir -p /etc/letsencrypt/renewal-hooks/deploy
            cat > /etc/letsencrypt/renewal-hooks/deploy/waterwall-cert.sh <<HOOK
#!/bin/sh
set -e
install -m 644 /etc/letsencrypt/live/$TUNNEL_DOMAIN/fullchain.pem $WW_ETC/certs/fullchain.pem
install -m 600 /etc/letsencrypt/live/$TUNNEL_DOMAIN/privkey.pem  $WW_ETC/certs/privkey.pem
systemctl try-restart waterwall.service
HOOK
            chmod 755 /etc/letsencrypt/renewal-hooks/deploy/waterwall-cert.sh
            systemctl enable --now certbot.timer >/dev/null 2>&1 || true
            ok "certificate installed (auto-renewal hook added)"
        else
            warn "Let's Encrypt failed (see /tmp/certbot.log) - falling back to self-signed."
            TLS_VERIFY=false
            write_selfsigned
        fi
    else
        write_selfsigned
        TLS_VERIFY=false
    fi
    sed -i "s|^TLS_VERIFY=.*|TLS_VERIFY=$TLS_VERIFY|" "$WW_STATE_FILE"
fi

# -------------------------------------------------------------- firewall ---
log "Installing the exit firewall"
cat > /usr/local/bin/ww-firewall <<FW
#!/usr/bin/env bash
# Generated by install-exit.sh - idempotent firewall for the exit server.
# Rules live in dedicated chains so re-running never duplicates them:
#   filter WWEXIT_IN / WWEXIT_FWD, nat WWEXIT_NAT, mangle WWEXIT_MSS
set -u
ACTION="\${1:-up}"
EXT_IF="\${EXT_IF:-$EXT_IF}"
TUNNEL_PORTS="$TUNNEL_PORTS"
WG_PORT="$EXIT_WG_PORT"

ipt() { local t="\$1"; shift; if [[ "\$t" == filter ]]; then iptables "\$@"; else iptables -t "\$t" "\$@"; fi; }
ensure_chain() { local t="\$1" c="\$2"; ipt "\$t" -n -L "\$c" >/dev/null 2>&1 || ipt "\$t" -N "\$c" 2>/dev/null || true; }
jump_ensure()   { local t="\$1" p="\$2" c="\$3"; ipt "\$t" -C "\$p" -j "\$c" 2>/dev/null || ipt "\$t" -I "\$p" 1 -j "\$c" 2>/dev/null || true; }
jump_remove()   { local t="\$1" p="\$2" c="\$3"; while ipt "\$t" -C "\$p" -j "\$c" 2>/dev/null; do ipt "\$t" -D "\$p" -j "\$c" 2>/dev/null || break; done; }

up() {
    local p
    for spec in filter:WWEXIT_IN filter:WWEXIT_FWD nat:WWEXIT_NAT mangle:WWEXIT_MSS; do
        ensure_chain "\${spec%%:*}" "\${spec##*:}"
        ipt "\${spec%%:*}" -F "\${spec##*:}" 2>/dev/null || true
    done
    jump_ensure filter INPUT WWEXIT_IN
    jump_ensure filter FORWARD WWEXIT_FWD
    jump_ensure nat POSTROUTING WWEXIT_NAT
    jump_ensure mangle FORWARD WWEXIT_MSS

    # --- incoming -----------------------------------------------------------
    for p in \$TUNNEL_PORTS; do ipt filter -A WWEXIT_IN -p tcp --dport "\$p" -j ACCEPT; done
    ipt filter -A WWEXIT_IN -p tcp --dport 80 -j ACCEPT      # certificate renewals
    ipt filter -A WWEXIT_IN -p tcp --dport 22 -j ACCEPT      # ssh
    # the WireGuard socket must never be reachable from the internet
    ipt filter -A WWEXIT_IN -p udp --dport "\$WG_PORT" ! -i lo -j DROP

    # --- forwarding ---------------------------------------------------------
    ipt filter -A WWEXIT_FWD -i wg0 -o "\$EXT_IF" -j ACCEPT
    ipt filter -A WWEXIT_FWD -i "\$EXT_IF" -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # --- MSS so TCP fits the 1280 byte tunnel MTU ---------------------------
    ipt mangle -A WWEXIT_MSS -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
    ipt mangle -A WWEXIT_MSS -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240

    # --- NAT: everything that leaves the tunnel leaves as this VPS ---------
    ipt nat -A WWEXIT_NAT -s $WG_CLIENT_NET -o "\$EXT_IF" -j MASQUERADE
    ipt nat -A WWEXIT_NAT -s $WG_TUN_NET -o "\$EXT_IF" -j MASQUERADE
    exit 0
}

down() {
    jump_remove mangle FORWARD WWEXIT_MSS
    jump_remove nat POSTROUTING WWEXIT_NAT
    jump_remove filter FORWARD WWEXIT_FWD
    jump_remove filter INPUT WWEXIT_IN
    ipt mangle -F WWEXIT_MSS 2>/dev/null || true
    ipt nat -F WWEXIT_NAT 2>/dev/null || true
    ipt filter -F WWEXIT_FWD 2>/dev/null || true
    ipt filter -F WWEXIT_IN 2>/dev/null || true
    ipt mangle -X WWEXIT_MSS 2>/dev/null || true
    ipt nat -X WWEXIT_NAT 2>/dev/null || true
    ipt filter -X WWEXIT_FWD 2>/dev/null || true
    ipt filter -X WWEXIT_IN 2>/dev/null || true
    exit 0
}

case "\$ACTION" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: ww-firewall up|down" >&2; exit 1 ;;
esac
FW
chmod 755 /usr/local/bin/ww-firewall

cat > /etc/systemd/system/ww-firewall.service <<'EOF'
[Unit]
Description=WaterWall exit firewall rules
DefaultDependencies=no
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ww-firewall up
ExecStop=/usr/local/bin/ww-firewall down

[Install]
WantedBy=multi-user.target
EOF

sysctl_write /etc/sysctl.d/99-waterwall-exit.conf \
    "net.ipv4.ip_forward=1" \
    "net.ipv4.conf.all.rp_filter=2" \
    "net.ipv4.conf.default.rp_filter=2" \
    "net.core.default_qdisc=fq" \
    "net.ipv4.tcp_congestion_control=bbr"

systemctl daemon-reload
systemctl enable ww-firewall.service >/dev/null 2>&1 || true
/usr/local/bin/ww-firewall up
ok "firewall active: tcp/${TUNNEL_PORTS// /,} open, udp/$EXIT_WG_PORT closed to the world"

# --------------------------------------------------------------- WireGuard --
log "Writing the exit WireGuard server (loopback only)"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
if [[ -f /etc/wireguard/wg0.conf ]] && ! grep -q 'waterwallwireguard' /etc/wireguard/wg0.conf; then
    cp -a /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.unrelated-$(date +%Y%m%d-%H%M%S).bak"
    warn "An unrelated /etc/wireguard/wg0.conf existed and was backed up."
fi

{
    printf '# managed by waterwallwireguard - install-exit.sh\n'
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$EXIT_WG_PRIV"
    printf 'Address = %s/24\n' "$EXIT_TUN_IP"
    printf 'MTU = 1280\n'
    printf 'ListenPort = %s\n' "$EXIT_WG_PORT"
    printf 'SaveConfig = false\n'
    printf 'PostUp = /usr/local/bin/ww-firewall up\n'
    printf 'PostDown = /usr/local/bin/ww-firewall down\n'
    if [[ -n "$MID_WG_PUB" ]]; then
        printf '\n[Peer]\n'
        printf '# middle server (WaterWall client side)\n'
        printf 'PublicKey = %s\n' "$MID_WG_PUB"
        printf 'AllowedIPs = %s, %s/32\n' "$WG_CLIENT_NET" "$MIDDLE_TUN_IP"
        printf 'PersistentKeepalive = 25\n'
    fi
} > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0.service >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0.service
if ! wg show wg0 >/dev/null 2>&1; then
    service_dump wg-quick@wg0.service
    die "The WireGuard interface wg0 did not come up."
fi
ok "WireGuard up on udp/$(wg show wg0 listen-port | head -1), address $EXIT_TUN_IP/24"

# ------------------------------------------------------------- WaterWall ----
export WW_ROLE=exit WW_MODE="$MODE" WW_PORT="$PORT" WW_PORT2="$PORT2"
export WW_EXIT_HOST="$EXIT_HOST" WW_SNI="$SNI" WW_COVER="$COVER" WW_COVER_PORT="$COVER_PORT"
export WW_SECRET="$SECRET" WW_TLS_VERIFY="$TLS_VERIFY"
export WW_CERT="$WW_ETC/certs/fullchain.pem" WW_KEY="$WW_ETC/certs/privkey.pem"
export WW_TARGET_HOST="127.0.0.1" WW_TARGET_PORT="$EXIT_WG_PORT"
export WW_WORKERS="$(nproc 2>/dev/null || echo 1)"
export WW_RAM_PROFILE="client"

log "Rendering the WaterWall configuration"
mkdir -p "$WW_ETC" "$WW_LOG" "$WW_VAR"
chmod 700 "$WW_ETC" "$WW_VAR"
ww_write_core
ww_write_config exit
ww_write_systemd
ww_apply

# ---------------------------------------------------------------- summary ---
token_from_state
JOIN_TOKEN="$(token_create)"
cat > /root/exit-join-token.txt <<EOF
# exit server join token for the middle installer (keep this secret)
$JOIN_TOKEN
EOF
chmod 600 /root/exit-join-token.txt

print_summary

cat <<EOF

${C_BOLD}JOIN TOKEN${C_RESET} (needed on the middle server, also saved in
/root/exit-join-token.txt):

${C_YELLOW}${JOIN_TOKEN}${C_RESET}

${C_BOLD}Next step${C_RESET} - on the Proxmox host, as root:

  SETUP_URL="https://raw.githubusercontent.com/${WW_REPO}/${WW_REF}/install-middle.sh"
  WW_JOIN='${JOIN_TOKEN}' bash -c "\$(curl -fsSL \$SETUP_URL)"

EOF

if [[ -z "$MID_WG_PUB" ]]; then
    warn "No middle public key yet. After the middle is installed it prints its key;"
    hint "re-run here: bash install-exit.sh --middle-pubkey <KEY>"
fi
