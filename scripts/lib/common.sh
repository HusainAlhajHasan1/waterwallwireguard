#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# common.sh - shared helpers for the WaterWall + WireGuard installers.
#
# This file is *sourced*, never executed. It is used by:
#   scripts/exit/install.sh              (runs on the exit VPS)
#   scripts/middle/install.sh            (runs on the Proxmox host)
#   scripts/middle/container-install.sh  (runs inside the new LXC)
#
# It deliberately depends on nothing but bash, coreutils and curl.
# ---------------------------------------------------------------------------
# shellcheck shell=bash

# Upstream project locations (override with env vars before running).
: "${WW_REPO:=HusainAlhajHasan1/waterwallwireguard}"
: "${WW_REF:=main}"
: "${WATERWALL_REPO:=radkesvat/WaterWall}"
: "${WATERWALL_VERSION:=latest}"
: "${WGDASH_REPO:=HusainAlhajHasan1/wireguard-dashboard}"
: "${WGDASH_REF:=main}"

# Where things live on disk (identical on both machines, which keeps the
# documentation and the troubleshooting commands short).
: "${WW_ETC:=/etc/waterwall}"
: "${WW_OPT:=/opt/waterwall}"
: "${WW_VAR:=/var/lib/waterwall}"
: "${WW_LOG:=/var/log/waterwall}"
: "${WW_STATE_FILE:=$WW_ETC/instance.env}"

# Colours (disabled automatically when stdout is not a terminal).
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

log()  { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
hint() { printf '    %s\n' "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

banner() {
    local width=74 line
    line=$(printf '%*s' "$width" '' | tr ' ' '=')
    printf '\n%s%s%s\n' "$C_BLUE" "$line" "$C_RESET"
    printf '%s  %s%s\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%s%s%s\n\n' "$C_BLUE" "$line" "$C_RESET"
}

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this as root (sudo bash ... or a root shell)."
}

need_cmd() {
    local missing=() c
    for c in "$@"; do have "$c" || missing+=("$c"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required command(s): ${missing[*]}"
    fi
}

retry() {
    # retry <attempts> <delay-seconds> <command...>
    local attempts="$1" delay="$2"; shift 2
    local n=1
    until "$@"; do
        if [[ $n -ge $attempts ]]; then
            return 1
        fi
        n=$((n + 1))
        sleep "$delay"
    done
}

http_get() {
    # http_get <url> [output-file]
    local url="$1" out="${2:-}"
    if [[ -n "$out" ]]; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$out" "$url"
    else
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "$url"
    fi
}

# ---------------------------------------------------------------- encoding ---
b64url_encode() {
    # stdin -> stdout
    base64 -w0 | tr '+/' '-_' | tr -d '='
}

b64url_decode() {
    # stdin -> stdout
    local data
    data=$(tr '_-' '/+' | tr -d '\n')
    case $(( ${#data} % 4 )) in
        2) data+="==" ;;
        3) data+="=" ;;
    esac
    printf '%s' "$data" | base64 -d
}

rand_str() {
    # rand_str [length] - alphanumeric random string.
    # Written without a long-running writer in the pipeline so that pipefail and
    # SIGPIPE can never abort the caller.
    local len="${1:-24}" pool=""
    if have openssl; then
        pool="$(openssl rand -base64 256 2>/dev/null | tr -dc 'A-Za-z0-9')" || pool=""
    fi
    if [[ -z "$pool" ]]; then
        pool="$(head -c 512 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')" || pool=""
    fi
    printf '%s' "${pool:0:len}"
}

# -------------------------------------------------------------- validation ---
is_ipv4() {
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$' o
    [[ $1 =~ $re ]] || return 1
    local IFS=.
    for o in $1; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

is_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

is_domain() {
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
    [[ ${1:-} =~ $re ]]
}

is_hostname_or_ip() { is_ipv4 "$1" || is_domain "$1"; }

# ------------------------------------------------------------------- input ---
# Prompts read from the controlling terminal so that the scripts keep working
# when they are piped into bash (curl ... | bash).
_tty() {
    if [[ -r /dev/tty ]]; then printf '%s' /dev/tty; else printf '%s' /dev/stdin; fi
}

prompt_var() {
    # prompt_var VAR "question" "default"
    local __var="$1" __q="$2" __def="${3:-}" __ans=""
    if [[ ! -t 0 ]] && [[ ! -r /dev/tty ]]; then
        printf -v "$__var" '%s' "$__def"
        return 0
    fi
    if [[ -n "$__def" ]]; then
        read -r -p "$__q [$__def]: " __ans < "$(_tty)" || true
    else
        read -r -p "$__q: " __ans < "$(_tty)" || true
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

prompt_secret() {
    # prompt_secret VAR "question" [min-length]
    local __var="$1" __q="$2" __min="${3:-10}" __ans=""
    if [[ ! -r /dev/tty ]]; then
        printf -v "$__var" '%s' ""
        return 0
    fi
    while :; do
        read -rs -p "$__q (min $__min chars, hidden): " __ans < /dev/tty || true
        printf '\n'
        (( ${#__ans} >= __min )) && break
        warn "Too short, try again."
    done
    printf -v "$__var" '%s' "$__ans"
}

confirm() {
    # confirm "question" [Y|N]
    local q="$1" def="${2:-N}" ans=""
    if [[ ! -r /dev/tty ]]; then
        [[ "$def" == "Y" ]]
        return
    fi
    read -r -p "$q [$def]: " ans < /dev/tty || true
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
}

# --------------------------------------------------------------- key-value ---
# Small root-owned KEY=VALUE state file, one assignment per line.
kv_save() {
    # kv_save <file> KEY=VALUE [KEY=VALUE ...]
    local file="$1"; shift
    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    {
        printf '# managed by waterwallwireguard installers - do not edit by hand\n'
        printf '%s\n' "$@"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

kv_load() {
    # kv_load <file> - sets the variables found in the file (KEY=VALUE lines).
    # Values may contain '=' (WireGuard keys are base64), so the split is done
    # with parameter expansion instead of IFS, which would eat a trailing '='.
    local file="$1" line key val
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        printf -v "$key" '%s' "$val"
        export "${key?}"
    done < "$file"
}

kv_get() {
    # kv_get <file> KEY -> prints the value (empty when missing)
    local file="$1" want="$2" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        if [[ "$key" == "$want" ]]; then printf '%s' "${line#*=}"; return 0; fi
    done < "$file"
}

# ------------------------------------------------------------ join tokens ---
# A join token is a URL-safe base64 blob of KEY=VALUE lines. It carries
# everything the middle server needs to build a byte-identical tunnel profile,
# so the whole deployment is two copy/paste commands.
TOKEN_KEYS="V MODE EXIT_HOST PORT PORT2 SNI COVER COVER_PORT SECRET TLS_VERIFY EXIT_WG_PORT EXIT_PUB MID_PUB MID_PRIV WW_VERSION CREATED"

token_create() {
    # Uses the current values of $TOKEN_KEYS (exported or local -v).
    local k out=""
    for k in $TOKEN_KEYS; do
        out+="$k=${!k:-}"$'\n'
    done
    printf '%s' "$out" | b64url_encode
}

token_parse() {
    local token="$1" payload line key val seen=0
    payload=$(printf '%s' "$token" | b64url_decode) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        if [[ " $TOKEN_KEYS " != *" $key "* ]]; then
            continue
        fi
        printf -v "$key" '%s' "$val"
        export "${key?}"
        seen=1
    done <<< "$payload"
    [[ $seen -eq 1 ]]
}

# The state file and the scripts use descriptive names (EXIT_WG_PUB,
# MID_WG_PRIV...), the compact token uses short ones (EXIT_PUB, MID_PRIV...).
# These two helpers keep the mapping in one place.
token_from_state() {
    V=1
    EXIT_PUB="${EXIT_WG_PUB:-}"
    MID_PUB="${MID_WG_PUB:-}"
    MID_PRIV="${MID_WG_PRIV:-}"
    EXIT_WG_PORT="${EXIT_WG_PORT:-51820}"
}

token_to_state() {
    EXIT_WG_PUB="${EXIT_PUB:-}"
    MID_WG_PUB="${MID_PUB:-}"
    MID_WG_PRIV="${MID_PRIV:-}"
    EXIT_WG_PORT="${EXIT_WG_PORT:-51820}"
}

# ---------------------------------------------------------------- packages ---
apt_install() {
    # apt_install pkg [pkg ...] - installs only what is missing.
    local missing=() p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    log "Installing packages: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

wait_for_network() {
    # wait_for_network [tries] - 2s between tries (default 30, i.e. ~60s).
    # A fresh container often needs a few seconds for DNS/route to settle.
    local tries="${1:-30}" i
    log "Waiting for network connectivity"
    for ((i = 1; i <= tries; i++)); do
        if curl -fsS --connect-timeout 4 --max-time 8 -o /dev/null https://deb.debian.org/ 2>/dev/null \
           || curl -fsS --connect-timeout 4 --max-time 8 -o /dev/null https://github.com/ 2>/dev/null; then
            ok "network is up"
            return 0
        fi
        sleep 2
    done
    warn "No internet after $((tries * 2))s - continuing, package downloads may fail."
    hint "Check DHCP/DNS inside the container: ip -4 addr ; cat /etc/resolv.conf ; curl -I https://deb.debian.org"
    return 0
}

detect_public_ipv4() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -fsS --connect-timeout 6 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    done
    return 1
}

default_interface() {
    local dev
    dev=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -n "$dev" ]] || dev=eth0
    printf '%s' "$dev"
}

sysctl_write() {
    # sysctl_write <file> "k=v" ["k=v" ...]
    #
    # Applies every key now and keeps only the ones this kernel lets us set.
    # An unprivileged container cannot write host-wide knobs (qdisc, BBR...);
    # dropping them from the file keeps the boot log clean instead of failing
    # on every start.
    local file="$1"; shift
    local kv kept=() dropped=()
    mkdir -p "$(dirname "$file")"
    for kv in "$@"; do
        if sysctl -qw "$kv" >/dev/null 2>&1; then
            kept+=("$kv")
        else
            dropped+=("$kv")
        fi
    done
    if [[ ${#kept[@]} -gt 0 ]]; then
        printf '# managed by waterwallwireguard installers\n' > "$file"
        printf '%s\n' "${kept[@]}" >> "$file"
    fi
    if [[ ${#dropped[@]} -gt 0 ]]; then
        info "not available in this container, skipped: ${dropped[*]}"
    fi
    return 0
}

wait_service() {
    # wait_service <unit> [seconds]
    local unit="$1" secs="${2:-15}" i
    for ((i = 1; i <= secs; i++)); do
        systemctl is-active --quiet "$unit" && return 0
        sleep 1
    done
    return 1
}

service_dump() {
    # service_dump <unit> - prints the last log lines, for failure reports.
    local unit="$1"
    printf '\n---- journalctl -u %s (last 40 lines) ----\n' "$unit" >&2
    journalctl -u "$unit" -n 40 --no-pager 2>/dev/null >&2 || true
    printf -- '-----------------------------------------\n' >&2
}
