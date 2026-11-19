#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-middle.sh - runs on the PROXMOX HOST (as root).
#
#  1. creates a Debian 13 LXC container on vmbr0 with a fixed LAN address
#  2. installs inside it: WireGuard (clients + tunnel), the WaterWall client
#     side of the tunnel, and the WireGuard Dashboard
#  3. configures policy routing so client traffic leaves through the tunnel
#
# It needs the join token printed by install-exit.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SELF_DIR/../lib/common.sh"

VMID=""
CT_HOSTNAME="wg-middle"
CT_IP=""            # empty = pick a free /24 address, "dhcp" allowed
CT_GW=""
BRIDGE="vmbr0"
STORAGE=""
TEMPLATE_STORAGE=""
TEMPLATE=""
CORES=2
MEMORY=1024
SWAP=512
DISK=8
DNS_SRV=""
UNPRIVILEGED=1
ROOT_PASS=""
WG_PORT="51820"
PUBLIC_HOST=""
DASH_DOMAIN=""
DASH_EMAIL=""
DASH_USER="admin"
DASH_PASS=""
TG_TOKEN=""
TG_ADMIN=""
JOIN="${WW_JOIN:-}"
SKIP_CREATE=0
FORCE=0

usage() {
    cat <<EOF
install-middle.sh - MIDDLE server installer (Proxmox host, creates an LXC)

Usage:
  WW_JOIN='<token>' bash install-middle.sh [options]

Required:
  --join TOKEN            Join token printed by install-exit.sh (or WW_JOIN env)

Container:
  --vmid ID               Container ID (default: next free ID from Proxmox)
  --hostname NAME         Container hostname (default: $CT_HOSTNAME)
  --ip ADDR[/CIDR]|dhcp   LAN address of the container (default: first free
                          address in the bridge subnet, e.g. 192.168.1.240)
  --gw ADDR               Gateway (default: the host default gateway)
  --bridge NAME           Proxmox bridge (default: vmbr0)
  --storage NAME          Storage for the container disk (default: detected)
  --template NAME         Template volume name (default: newest Debian 13)
  --cores N               vCPUs (default: $CORES)
  --memory MB             RAM in MiB (default: $MEMORY)
  --disk GB               Disk size in GiB (default: $DISK)
  --dns ADDR              DNS server for the container
  --privileged            Create a privileged container (default: unprivileged)

WireGuard / dashboard:
  --wg-port PORT          UDP port clients connect to (default: $WG_PORT)
  --public-host HOST      Public IP or DDNS name clients use
                          (default: detected public IPv4 of your home line)
  --dash-domain DOMAIN    Serve the dashboard on https://DOMAIN (needs router
                          port forward 80/443 and DNS pointing at home)
  --dash-email EMAIL      Let's Encrypt contact address
  --dash-user USER        Dashboard admin username (default: $DASH_USER)
  --dash-pass PASS        Dashboard admin password (default: generated)
  --telegram-token TOKEN  Optional Telegram bot token
  --telegram-admin ID     Optional Telegram admin chat ID
  --reuse                 Install into an existing container without asking
  -h, --help              This help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --join)            JOIN="$2"; shift 2 ;;
        --vmid)            VMID="$2"; shift 2 ;;
        --hostname)        CT_HOSTNAME="$2"; shift 2 ;;
        --ip)              CT_IP="$2"; shift 2 ;;
        --gw)              CT_GW="$2"; shift 2 ;;
        --bridge)          BRIDGE="$2"; shift 2 ;;
        --storage)         STORAGE="$2"; shift 2 ;;
        --template)        TEMPLATE="$2"; shift 2 ;;
        --cores)           CORES="$2"; shift 2 ;;
        --memory)          MEMORY="$2"; shift 2 ;;
        --disk)            DISK="$2"; shift 2 ;;
        --dns)             DNS_SRV="$2"; shift 2 ;;
        --privileged)      UNPRIVILEGED=0; shift ;;
        --wg-port)         WG_PORT="$2"; shift 2 ;;
        --public-host)     PUBLIC_HOST="$2"; shift 2 ;;
        --dash-domain)     DASH_DOMAIN="$2"; shift 2 ;;
        --dash-email)      DASH_EMAIL="$2"; shift 2 ;;
        --dash-user)       DASH_USER="$2"; shift 2 ;;
        --dash-pass)       DASH_PASS="$2"; shift 2 ;;
        --telegram-token)  TG_TOKEN="$2"; shift 2 ;;
        --telegram-admin)  TG_ADMIN="$2"; shift 2 ;;
        --reuse)           SKIP_CREATE=1; shift ;;
        --force)           FORCE=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "Unknown option: $1 (try --help)" ;;
    esac
done

need_root
have pveversion || die "This script must run on a Proxmox VE host (pveversion not found)."
have pct || die "pct (Proxmox container tools) not found."
have pvesm || die "pvesm not found - is this really a Proxmox host?"

[[ -n "$JOIN" ]] || die "Missing --join TOKEN. Run install-exit.sh on the VPS first; it prints the token.
It is also stored in /root/exit-join-token.txt there."
is_port "$WG_PORT" || die "--wg-port must be a valid UDP port."
if [[ -n "$DASH_DOMAIN" ]]; then
    is_domain "$DASH_DOMAIN" || die "--dash-domain must be a domain name."
    [[ -n "$DASH_EMAIL" ]] || DASH_EMAIL="admin@$DASH_DOMAIN"
fi
[[ -n "$DASH_PASS" ]] || DASH_PASS="$(rand_str 16)"
[[ -n "$ROOT_PASS" ]] || ROOT_PASS="$(rand_str 20)"

# Decode the token here too: the container installer gets the same token, but
# we want the tunnel mode early for the summary and sanity checks.
token_parse "$JOIN" || die "The join token could not be decoded - copy it again, exactly as printed."
token_to_state
[[ -n "${MODE:-}" ]] || die "The join token is missing MODE."
[[ -n "${EXIT_HOST:-}" ]] || die "The join token is missing EXIT_HOST."
[[ -n "${PORT:-}" ]] || die "The join token is missing PORT."
if [[ "${MODE:-}" == split && -z "${PORT2:-}" ]]; then
    PORT2="$((PORT + 1))"
fi

banner "Middle server installer (Proxmox host)"
info "Tunnel mode   : $MODE"
info "Exit server   : $EXIT_HOST:$PORT${PORT2:+/$PORT2}"
info "Container     : $CT_HOSTNAME"

# ----------------------------------------------------------- host details --
log "Inspecting the Proxmox host"
PVE_VERSION="$(pveversion | head -1)"
ok "$PVE_VERSION"

if ! ip -4 addr show "$BRIDGE" >/dev/null 2>&1; then
    warn "Bridge $BRIDGE has no IPv4 address."
    hint "Available bridges: $(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')"
    die "Pick one with --bridge."
fi

BRIDGE_CIDR="$(ip -4 -o addr show dev "$BRIDGE" | awk '{print $4; exit}')"
BRIDGE_ADDR="${BRIDGE_CIDR%%/*}"
[[ -n "$CT_GW" ]] || CT_GW="$(ip -4 route show default | awk '/default/ {print $3; exit}')"
[[ -n "$CT_GW" ]] || die "Could not detect the gateway, pass --gw."

if [[ -z "$CT_IP" ]]; then
    PREFIX="${BRIDGE_CIDR#*/}"
    BASE="$(printf '%s' "$BRIDGE_ADDR" | cut -d. -f1-3)"
    if [[ "$PREFIX" != "24" ]]; then
        die "The bridge subnet is /$PREFIX, please pass --ip ADDR/CIDR explicitly."
    fi
    log "Looking for a free address in $BASE.0/24"
    BUSY="$( { ip -4 neigh show | awk '{print $1}'
                ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1; } | sort -u )"
    CT_IP=""
    for ((i = 240; i >= 100; i--)); do
        cand="$BASE.$i"
        [[ "$cand" == "$BRIDGE_ADDR" ]] && continue
        grep -qxF "$cand" <<< "$BUSY" && continue
        if ping -c1 -W1 "$cand" >/dev/null 2>&1; then continue; fi
        CT_IP="$cand"; break
    done
    [[ -n "$CT_IP" ]] || die "No free address found in $BASE.0/24 - pass --ip."
    IPCONF="$CT_IP/24"
    ok "Using free address $IPCONF"
else
    if [[ "$CT_IP" == "dhcp" ]]; then
        IPCONF="dhcp"
    else
        IPCONF="$CT_IP"
        [[ "$IPCONF" == */* ]] || IPCONF="$IPCONF/24"
        is_ipv4 "${IPCONF%%/*}" || die "--ip must be an IPv4 address or 'dhcp'."
    fi
fi
ok "Container address: $IPCONF, gateway $CT_GW"

[[ -n "$DNS_SRV" ]] || DNS_SRV="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
[[ -n "$DNS_SRV" ]] || DNS_SRV="1.1.1.1"
[[ "$DNS_SRV" == "127.0.0.1" || "$DNS_SRV" == "127.0.0.53" || -z "$DNS_SRV" ]] && DNS_SRV="1.1.1.1"

# -------------------------------------------------------------- storage ----
if [[ -z "$STORAGE" ]]; then
    log "Detecting storage for the container disk"
    STORAGE="$(pvesm status --content rootdir 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1, $6}' | sort -k2 -n -r | awk 'NR==1 {print $1}')"
    [[ -n "$STORAGE" ]] || die "No storage with 'rootdir' content found. Pass --storage."
fi
STORAGE_TYPE="$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $2}')"
ok "Disk storage: $STORAGE ($STORAGE_TYPE)"

if [[ -z "$TEMPLATE_STORAGE" ]]; then
    TEMPLATE_STORAGE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
    [[ -n "$TEMPLATE_STORAGE" ]] || TEMPLATE_STORAGE=local
fi

# --------------------------------------------------------------- template --
if [[ -z "$TEMPLATE" ]]; then
    log "Looking for a Debian container template"
    if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q 'debian-1[23]-standard'; then
        pveam update >/dev/null 2>&1 || warn "pveam update failed - template list may be stale."
    fi
    TEMPLATE="$(pveam available --section system 2>/dev/null | awk '{print $2}' \
        | grep -E '^debian-1[23]-standard_.*_amd64\.tar\.(zst|gz)$' | sort -V | tail -1)"
    [[ -n "$TEMPLATE" ]] || die "No debian template available. Run 'pveam update' and pass --template."
fi
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "/$TEMPLATE\$"; then
    log "Downloading $TEMPLATE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Could not download the template."
fi
TEMPLATE_SPEC="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"
ok "Template: $TEMPLATE_SPEC"

# ------------------------------------------------------------- container ---
if [[ -z "$VMID" ]]; then
    # A container this installer created before (same hostname) is reconfigured
    # instead of creating a second one on the next free ID.
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        if [[ "$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname/ {print $2; exit}')" == "$CT_HOSTNAME" ]]; then
            VMID="$id"
            REUSED_AUTO=1
            info "Found the container this installer created earlier: $VMID ($CT_HOSTNAME)"
            break
        fi
    done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
fi
if [[ -z "$VMID" ]]; then
    VMID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
    [[ -n "$VMID" ]] || die "Could not determine the next free container ID; pass --vmid."
fi
[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid must be numeric."

REUSED_AUTO="${REUSED_AUTO:-0}"
CT_EXISTS=0
if pct status "$VMID" >/dev/null 2>&1; then
    CT_EXISTS=1
fi

if [[ $CT_EXISTS -eq 1 ]]; then
    EXIST_NAME="$(pct config "$VMID" | awk -F': ' '/^hostname/ {print $2}')"
    if [[ $SKIP_CREATE -eq 0 && $FORCE -eq 0 ]]; then
        warn "Container $VMID already exists ($EXIST_NAME)."
        confirm "Reinstall inside the existing container $VMID?" Y \
            || die "Aborted. Use --vmid to pick another ID, or --reuse to skip this question."
    fi
    log "Reusing container $VMID"
    pct status "$VMID" | grep -q running || pct start "$VMID"
else
    log "Creating container $VMID ($CORES vCPU, ${MEMORY}MiB RAM, ${DISK}GiB disk)"
    MAC="BC:24:11:$(openssl rand -hex 3 | sed 's/\(..\)/\1:/g; s/:$//')"
    NET="name=eth0,bridge=$BRIDGE,ip=$IPCONF,gw=$CT_GW,hwaddr=$MAC,firewall=1,type=veth"
    [[ "$IPCONF" == "dhcp" ]] && NET="name=eth0,bridge=$BRIDGE,ip=dhcp,gw=$CT_GW,hwaddr=$MAC,firewall=1,type=veth"

    CREATE_ARGS=(
        "$VMID" "$TEMPLATE_SPEC"
        --hostname "$CT_HOSTNAME"
        --cores "$CORES" --memory "$MEMORY" --swap "$SWAP"
        --rootfs "$STORAGE:$DISK"
        --net0 "$NET"
        --nameserver "$DNS_SRV"
        --ostype debian --arch amd64
        --onboot 1
        --unprivileged "$UNPRIVILEGED"
        --features "nesting=1,keyctl=1"
        --description "WireGuard middle server (dashboard + WaterWall tunnel to $EXIT_HOST)"
        --password "$ROOT_PASS"
    )
    if [[ -f /root/.ssh/authorized_keys ]]; then
        CREATE_ARGS+=(--ssh-public-keys /root/.ssh/authorized_keys)
    fi
    pct create "${CREATE_ARGS[@]}" || die "pct create failed."
    pct start "$VMID" || die "Could not start container $VMID."
fi

log "Waiting for container $VMID to boot"
for _ in {1..60}; do
    if pct exec "$VMID" -- true >/dev/null 2>&1; then break; fi
    sleep 1
done
pct exec "$VMID" -- true >/dev/null 2>&1 || die "Cannot execute commands inside container $VMID."

# ------------------------------------------------ WireGuard inside the LXC --
log "Loading the kernel modules the container needs"
for m in wireguard iptable_nat iptable_mangle xt_MASQUERADE nf_conntrack; do
    modprobe "$m" 2>/dev/null || true
done

# pct conf edits need /etc/pve/lxc; on a cluster member the config lives in
# the pmxcfs anyway. Refuse to touch a file we cannot write instead of dying
# with a shell error.
pve_conf_path() {
    local id="$1"
    if [[ -d /etc/pve/lxc ]]; then
        printf '/etc/pve/lxc/%s.conf' "$id"
    elif [[ -d /var/lib/lxc ]]; then
        printf '/var/lib/lxc/%s/config' "$id"
    fi
}

append_conf_line() {   # append_conf_line <conf> <key> <line>
    local conf="$1" key="$2" line="$3"
    [[ -n "$conf" && -f "$conf" ]] || return 1
    grep -q "^$key" "$conf" && return 0
    printf '%s\n' "$line" >> "$conf" 2>/dev/null || return 1
    return 0
}

log "Checking that the container may create WireGuard interfaces"
if pct exec "$VMID" -- bash -c 'ip link add wgprobe0 type wireguard 2>/dev/null && ip link del wgprobe0 2>/dev/null' ; then
    ok "WireGuard interfaces are allowed inside the container"
else
    if [[ $UNPRIVILEGED -eq 1 ]]; then
        warn "WireGuard interface creation is blocked - relaxing the AppArmor profile of container $VMID"
        CONF="$(pve_conf_path "$VMID")"
        if ! append_conf_line "$CONF" "lxc.apparmor.profile" "lxc.apparmor.profile: lxc-container-default-cgns"; then
            warn "Could not edit the container config by hand - set it manually:"
            hint "  lxc.apparmor.profile: lxc-container-default-cgns   (in the config of container $VMID)"
        fi
        pct stop "$VMID" >/dev/null 2>&1 || true
        pct start "$VMID"
        for _ in {1..30}; do pct exec "$VMID" -- true >/dev/null 2>&1 && break; sleep 1; done
        if pct exec "$VMID" -- bash -c 'ip link add wgprobe0 type wireguard 2>/dev/null && ip link del wgprobe0 2>/dev/null'; then
            ok "WireGuard works after relaxing AppArmor"
        else
            warn "WireGuard still cannot create interfaces. Consider: --privileged"
        fi
    else
        warn "WireGuard is not available inside the container - is the wireguard module loaded on the host?"
    fi
fi
log "Checking that the container may enable IP forwarding"
if [[ "$(pct exec "$VMID" -- sh -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null | tr -d '\r')" != "1" ]]; then
    warn "IP forwarding is read-only inside the container - adding proc/sys mounts"
    CONF="$(pve_conf_path "$VMID")"
    if ! append_conf_line "$CONF" "lxc.mount.auto" "lxc.mount.auto: proc:rw sys:rw"; then
        warn "Could not edit the container config by hand - try manually:"
        hint "  lxc.mount.auto: proc:rw sys:rw   (in the config of container $VMID, then restart it)"
    fi
    pct stop "$VMID" >/dev/null 2>&1 || true
    pct start "$VMID"
    for _ in {1..30}; do pct exec "$VMID" -- true >/dev/null 2>&1 && break; sleep 1; done
    pct exec "$VMID" -- sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
    if [[ "$(pct exec "$VMID" -- cat /proc/sys/net/ipv4/ip_forward 2>/dev/null | tr -d '\r')" == "1" ]]; then
        ok "IP forwarding enabled inside the container"
    else
        warn "Still no forwarding inside the container - see the notes in README.md"
    fi
else
    ok "IP forwarding is writable inside the container"
fi

# ------------------------------------------------------- push the tooling ---
log "Copying the installer into container $VMID"
pct exec "$VMID" -- mkdir -p /root/ww-setup/lib
for f in lib/common.sh lib/waterwall.sh; do
    pct push "$VMID" "$REPO_ROOT/scripts/$f" "/root/ww-setup/$f" -perms 0644
done
pct push "$VMID" "$REPO_ROOT/scripts/middle/middle-routes.sh" /root/ww-setup/middle-routes.sh -perms 0755
pct push "$VMID" "$REPO_ROOT/scripts/middle/wgmw-doctor.sh" /root/ww-setup/wgmw-doctor.sh -perms 0755
pct push "$VMID" "$REPO_ROOT/scripts/middle/container-install.sh" /root/ww-setup/container-install.sh -perms 0755

# ------------------------------------------------------------ run it ------
log "Installing WireGuard, WaterWall and the dashboard inside container $VMID"
info "(this takes a few minutes)"
CT_ARGS=(--wg-port "$WG_PORT" --admin-user "$DASH_USER" --admin-pass "$DASH_PASS")
[[ -n "$PUBLIC_HOST" ]] && CT_ARGS+=(--public-host "$PUBLIC_HOST")
[[ -n "$DASH_DOMAIN" ]] && CT_ARGS+=(--dash-domain "$DASH_DOMAIN" --dash-email "$DASH_EMAIL")
[[ -n "$TG_TOKEN" ]] && CT_ARGS+=(--telegram-token "$TG_TOKEN")
[[ -n "$TG_ADMIN" ]] && CT_ARGS+=(--telegram-admin "$TG_ADMIN")

set +e
pct exec "$VMID" -- env WW_JOIN="$JOIN" WW_REPO="$WW_REPO" WW_REF="$WW_REF" \
    WATERWALL_VERSION="$WATERWALL_VERSION" WGDASH_REPO="$WGDASH_REPO" WGDASH_REF="$WGDASH_REF" \
    bash /root/ww-setup/container-install.sh "${CT_ARGS[@]}"
CT_RC=$?
set -e
[[ $CT_RC -eq 0 ]] || die "The in-container installation failed (exit code $CT_RC)."

# ------------------------------------------------------------- summary -----
MID_PUB="$(pct exec "$VMID" -- cat /etc/waterwall/middle-pubkey.txt 2>/dev/null | tr -d '\r\n' || true)"
[[ -n "$MID_PUB" ]] || MID_PUB="$(pct exec "$VMID" -- wg show wg1 public-key 2>/dev/null | tr -d '\r\n' || true)"
# Ask the container for the address it really has (matters when an existing
# container is reused and its address differs from the requested one).
CT_ADDR_ACTUAL="$(pct exec "$VMID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n')"
if [[ "$IPCONF" == "dhcp" ]]; then
    CT_ADDR="${CT_ADDR_ACTUAL:-<container-ip>}"
else
    CT_ADDR="${IPCONF%%/*}"
    if [[ -n "$CT_ADDR_ACTUAL" && "$CT_ADDR_ACTUAL" != "$CT_ADDR" && "$CT_ADDR_ACTUAL" != "$BRIDGE_ADDR" ]]; then
        if [[ $REUSED_AUTO -eq 1 ]]; then
            info "Container $VMID already uses $CT_ADDR_ACTUAL - keeping that address."
        else
            warn "Container $VMID actually uses $CT_ADDR_ACTUAL (requested $CT_ADDR) - using the real address."
        fi
        CT_ADDR="$CT_ADDR_ACTUAL"
    fi
fi

if [[ -n "$DASH_DOMAIN" ]]; then
    DASH_URL="https://$DASH_DOMAIN"
    DASH_FALLBACK="http://$CT_ADDR:8080   (only if the certificate failed)"
else
    DASH_URL="http://$CT_ADDR:8080"
    DASH_FALLBACK=""
fi

banner "Middle server is ready"
cat <<EOF
  Container        : $VMID ($CT_HOSTNAME)
  Address          : $CT_ADDR (gateway $CT_GW on $BRIDGE)
  Tunnel mode      : $MODE  (-> $EXIT_HOST:$PORT)
  WireGuard clients: udp/$WG_PORT
  Middle public key: ${MID_PUB:-unknown}
  Dashboard        : $DASH_URL
                     user: $DASH_USER
                     pass: $DASH_PASS${DASH_FALLBACK:+
                     fallback: $DASH_FALLBACK}
  Container root   : password $ROOT_PASS   (pct console $VMID)

${C_BOLD}Router (your home router) - forward these to $CT_ADDR:${C_RESET}

  udp/$WG_PORT   -> $CT_ADDR:$WG_PORT     ${C_GREEN}REQUIRED${C_RESET} (this is what clients connect to)
EOF
if [[ -n "$DASH_DOMAIN" ]]; then
cat <<EOF
  tcp/80         -> $CT_ADDR:80           ${C_YELLOW}optional${C_RESET} (dashboard HTTPS + certificate renewal)
  tcp/443        -> $CT_ADDR:443          ${C_YELLOW}optional${C_RESET} (dashboard HTTPS)
  DNS: $DASH_DOMAIN -> your home public IP
EOF
fi
cat <<EOF

${C_BOLD}Clients:${C_RESET} add them in the dashboard, the config they download already routes
everything through the exit server.

  pct enter $VMID
  wgdash status | wgdash add phone | wg show

EOF
