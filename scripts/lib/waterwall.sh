#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# waterwall.sh - install the WaterWall core and render the tunnel profiles.
#
# Sourced by the installers (after common.sh). One single place builds the
# WaterWall JSON for both machines, so the middle and the exit can never drift
# apart: the exit generates the profile parameters, packs them into a join
# token, and the middle renders its own JSON from the very same values.
#
# Three tunnel modes are supported:
#
#   halfduplex  TLS 1.3 + HalfDuplex (upload/download split over two
#               connections that share one port) + UDP-over-TCP.
#   split       TLS 1.3 + HalfDuplex with the upload and the download paths
#               pinned to two different ports/services.
#   reality     Reality v2 camouflage (a genuine TLS 1.3 handshake with a real
#               public HTTPS site, no certificate of your own required).
#
# In every mode the payload that crosses the tunnel is a WireGuard tunnel
# (middle wg1 <-> exit wg0), so the transport layer only has to look normal.
# ---------------------------------------------------------------------------
# shellcheck shell=bash

WW_MODES="halfduplex split reality"

ww_asset_name() {
    # ww_asset_name <arch> [variant]  (arch: x64 | arm64)
    local arch="$1" variant="${2:-}"
    case "$arch" in
        x64)   [[ -n "$variant" ]] && printf 'Waterwall-linux-gcc-x64-%s.zip' "$variant" || printf 'Waterwall-linux-gcc-x64.zip' ;;
        arm64) printf 'Waterwall-linux-gcc-arm64.zip' ;;
        *)     printf 'Waterwall-linux-gcc-x64.zip' ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *)             printf 'x64' ;;
    esac
}

ww_download_url() {
    local asset="$1"
    if [[ "$WATERWALL_VERSION" == "latest" ]]; then
        printf 'https://github.com/%s/releases/latest/download/%s' "$WATERWALL_REPO" "$asset"
    else
        printf 'https://github.com/%s/releases/download/%s/%s' "$WATERWALL_REPO" "$WATERWALL_VERSION" "$asset"
    fi
}

ww_install_binary() {
    local arch asset url tmp zip binary
    arch="$(detect_arch)"
    asset="$(ww_asset_name "$arch")"
    binary="$WW_OPT/Waterwall"

    mkdir -p "$WW_OPT" "$WW_OPT/libs" "$WW_ETC" "$WW_VAR" "$WW_LOG"

    if [[ -x "$binary" ]] && "$binary" --version >/dev/null 2>&1; then
        ok "WaterWall core already installed ($("$binary" --version 2>/dev/null | head -1))"
        return 0
    fi

    apt_install curl ca-certificates unzip
    tmp="$(mktemp -d)"
    url="$(ww_download_url "$asset")"
    log "Downloading WaterWall ($asset)"
    info "$url"
    if ! http_get "$url" "$tmp/ww.zip"; then
        warn "Download failed: $url"
        rm -rf "$tmp"
        # Fall back to the pre-Haswell build, which runs everywhere.
        asset="$(ww_asset_name "$arch" old-cpu)"
        url="$(ww_download_url "$asset")"
        info "Retrying with $url"
        http_get "$url" "$tmp/ww.zip" || { rm -rf "$tmp"; die "Could not download WaterWall from GitHub."; }
    fi

    unzip -o -q "$tmp/ww.zip" -d "$tmp" || { rm -rf "$tmp"; die "Could not unpack $asset"; }
    local found
    found="$(find "$tmp" -maxdepth 2 -type f -name 'Waterwall*' ! -name '*.zip' | head -1)"
    [[ -n "$found" ]] || { rm -rf "$tmp"; die "No Waterwall executable inside $asset"; }
    install -m 0755 "$found" "$binary"
    rm -rf "$tmp"

    if ! "$binary" --version >/dev/null 2>&1; then
        warn "This CPU cannot run the default build, switching to the old-cpu build."
        tmp="$(mktemp -d)"
        asset="$(ww_asset_name "$arch" old-cpu)"
        http_get "$(ww_download_url "$asset")" "$tmp/ww.zip" || die "Could not download the old-cpu WaterWall build."
        unzip -o -q "$tmp/ww.zip" -d "$tmp" || die "Could not unpack $asset"
        found="$(find "$tmp" -maxdepth 2 -type f -name 'Waterwall*' ! -name '*.zip' | head -1)"
        install -m 0755 "$found" "$binary"
        rm -rf "$tmp"
        "$binary" --version >/dev/null 2>&1 || die "The WaterWall binary does not run on this CPU."
    fi
    ok "WaterWall installed: $("$binary" --version 2>/dev/null | head -1)"
}

# ------------------------------------------------------------------ core ----
ww_write_core() {
    local workers="${WW_WORKERS:-1}" profile="${WW_RAM_PROFILE:-client}" cfg
    if [[ "${WW_ROLE:-middle}" == middle ]]; then cfg=middle.json; else cfg=exit.json; fi
    cat > "$WW_ETC/core.json" <<EOF
{
  "log": {
    "path": "$WW_LOG/",
    "core":    { "loglevel": "INFO",    "file": "core.log",     "console": false },
    "network": { "loglevel": "INFO",    "file": "network.log",  "console": false },
    "dns":     { "loglevel": "INFO",    "file": "dns.log",      "console": false },
    "internal":{ "loglevel": "WARNING", "file": "internal.log", "console": false }
  },
  "misc": {
    "workers": $workers,
    "ram-profile": "$profile",
    "mtu": 1500,
    "tcp-tune": true,
    "try-enabling-bbr": true,
    "libs-path": "$WW_OPT/libs/"
  },
  "dns": {
    "domain-strategy": "prefer-ipv4"
  },
  "configs": [
    "$WW_ETC/$cfg"
  ]
}
EOF
    chmod 644 "$WW_ETC/core.json"
}

# --------------------------------------------------------------- profiles ---
#
# Variables consumed here (all set by the caller):
#   WW_ROLE            middle | exit
#   WW_MODE            halfduplex | split | reality
#   WW_EXIT_HOST       exit server address (IP or hostname), middle side only
#   WW_PORT            primary tunnel TCP port on the exit
#   WW_PORT2           second tunnel TCP port (split mode only)
#   WW_SNI             SNI used by the middle (cover domain in reality mode)
#   WW_COVER           cover HTTPS site the exit relays to (reality mode)
#   WW_COVER_PORT      cover HTTPS port (default 443)
#   WW_SECRET          Reality password (reality mode only)
#   WW_TLS_VERIFY      true|false - verify the exit certificate (TLS modes)
#   WW_CERT / WW_KEY   certificate paths on the exit (TLS modes)
#   WW_LOCAL_UDP_PORT  middle: local UDP port that receives WireGuard packets
#   WW_TARGET_PORT     exit: local WireGuard UDP port
#
ww_tls_client_block() {
    # ww_tls_client_block <node-name> <port>
    local name="$1" port="$2" verify="${WW_TLS_VERIFY:-false}"
    cat <<EOF
    {
      "name": "$name",
      "type": "TlsClient",
      "settings": {
        "sni": "$WW_SNI",
        "alpns": ["h2", "http/1.1"],
        "verify": $verify
      },
      "next": "tcp-$port"
    },
    {
      "name": "tcp-$port",
      "type": "TcpConnector",
      "settings": {
        "address": "$WW_EXIT_HOST",
        "port": $port,
        "nodelay": true
      }
    }
EOF
}

ww_tls_server_block() {
    # ww_tls_server_block <node-name> <next-node>
    local name="$1" next="$2"
    cat <<EOF
    {
      "name": "$name",
      "type": "TlsServer",
      "settings": {
        "cert-file": "${WW_CERT:-$WW_ETC/certs/fullchain.pem}",
        "key-file": "${WW_KEY:-$WW_ETC/certs/privkey.pem}",
        "select-alpns": ["h2", "http/1.1"],
        "min-version": "TLSv1.3",
        "session-tickets": true
      },
      "next": "$next"
    }
EOF
}

ww_reality_password() {
    # Reality limits the shared secret to 32 UTF-8 bytes.
    local s="${WW_SECRET:-}"
    [[ -n "$s" ]] || s="$(rand_str 24)"
    printf '%s' "${s:0:32}"
}

ww_write_config() {
    local role="$1" out mode
    mode="${WW_MODE:?missing WW_MODE}"
    case "$mode" in
        halfduplex|split|reality) ;;
        *) die "Unknown tunnel mode: $mode (expected: $WW_MODES)" ;;
    esac

    if [[ "$role" == middle ]]; then
        out="$WW_ETC/middle.json"
        local lport="${WW_LOCAL_UDP_PORT:-51821}"
        case "$mode" in
            halfduplex)
                cat > "$out" <<EOF
{
  "name": "middle-halfduplex",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "wireguard-in",
      "type": "UdpListener",
      "settings": {
        "address": "127.0.0.1",
        "port": $lport,
        "large-send-buffer": true,
        "large-recv-buffer": true
      },
      "next": "udp-over-tcp"
    },
    {
      "name": "udp-over-tcp",
      "type": "UdpOverTcpClient",
      "settings": {},
      "next": "half-duplex"
    },
    {
      "name": "half-duplex",
      "type": "HalfDuplexClient",
      "settings": {},
      "next": "tls-out"
    },
$(ww_tls_client_block "tls-out" "$WW_PORT")
  ]
}
EOF
                ;;
            split)
                cat > "$out" <<EOF
{
  "name": "middle-halfduplex-split",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "wireguard-in",
      "type": "UdpListener",
      "settings": {
        "address": "127.0.0.1",
        "port": $lport,
        "large-send-buffer": true,
        "large-recv-buffer": true
      },
      "next": "udp-over-tcp"
    },
    {
      "name": "udp-over-tcp",
      "type": "UdpOverTcpClient",
      "settings": {},
      "next": "half-duplex"
    },
    {
      "name": "half-duplex",
      "type": "HalfDuplexClient",
      "settings": {
        "upload": "tls-up",
        "download": "tls-down"
      }
    },
$(ww_tls_client_block "tls-up" "$WW_PORT"),
$(ww_tls_client_block "tls-down" "${WW_PORT2:?missing WW_PORT2}")
  ]
}
EOF
                ;;
            reality)
                cat > "$out" <<EOF
{
  "name": "middle-reality",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "wireguard-in",
      "type": "UdpListener",
      "settings": {
        "address": "127.0.0.1",
        "port": $lport,
        "large-send-buffer": true,
        "large-recv-buffer": true
      },
      "next": "udp-over-tcp"
    },
    {
      "name": "udp-over-tcp",
      "type": "UdpOverTcpClient",
      "settings": {},
      "next": "reality-out"
    },
    {
      "name": "reality-out",
      "type": "RealityClient",
      "settings": {
        "sni": "$WW_SNI",
        "verify": true,
        "password": "$(ww_reality_password)",
        "algorithm": "chacha20-poly1305",
        "salt": "waterwall-reality",
        "kdf-iterations": 12000
      },
      "next": "exit-tcp"
    },
    {
      "name": "exit-tcp",
      "type": "TcpConnector",
      "settings": {
        "address": "$WW_EXIT_HOST",
        "port": $WW_PORT,
        "nodelay": true
      }
    }
  ]
}
EOF
                ;;
        esac
    else
        out="$WW_ETC/exit.json"
        local tport="${WW_TARGET_PORT:-51820}" thost="${WW_TARGET_HOST:-127.0.0.1}"
        case "$mode" in
            halfduplex)
                cat > "$out" <<EOF
{
  "name": "exit-halfduplex",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "tunnel-in",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $WW_PORT, "nodelay": true },
      "next": "tls-in"
    },
$(ww_tls_server_block "tls-in" "half-duplex-server"),
    {
      "name": "half-duplex-server",
      "type": "HalfDuplexServer",
      "settings": {},
      "next": "udp-over-tcp-server"
    },
    {
      "name": "udp-over-tcp-server",
      "type": "UdpOverTcpServer",
      "settings": {},
      "next": "local-wireguard"
    },
    {
      "name": "local-wireguard",
      "type": "UdpConnector",
      "settings": { "address": "$thost", "port": $tport }
    }
  ]
}
EOF
                ;;
            split)
                cat > "$out" <<EOF
{
  "name": "exit-halfduplex-split",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "tunnel-in-up",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $WW_PORT, "nodelay": true },
      "next": "tls-in-up"
    },
$(ww_tls_server_block "tls-in-up" "half-duplex-primary"),
    {
      "name": "half-duplex-primary",
      "type": "HalfDuplexServer",
      "settings": {},
      "next": "udp-over-tcp-server"
    },
    {
      "name": "udp-over-tcp-server",
      "type": "UdpOverTcpServer",
      "settings": {},
      "next": "local-wireguard"
    },
    {
      "name": "local-wireguard",
      "type": "UdpConnector",
      "settings": { "address": "$thost", "port": $tport }
    },
    {
      "name": "tunnel-in-down",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": ${WW_PORT2:?missing WW_PORT2}, "nodelay": true },
      "next": "tls-in-down"
    },
$(ww_tls_server_block "tls-in-down" "half-duplex-secondary"),
    {
      "name": "half-duplex-secondary",
      "type": "HalfDuplexServer",
      "settings": { "pair": "half-duplex-primary" }
    }
  ]
}
EOF
                ;;
            reality)
                cat > "$out" <<EOF
{
  "name": "exit-reality",
  "author": "waterwallwireguard-installer",
  "config-version": 1,
  "nodes": [
    {
      "name": "tunnel-in",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $WW_PORT, "nodelay": true },
      "next": "reality-in"
    },
    {
      "name": "reality-in",
      "type": "RealityServer",
      "settings": {
        "destination": "cover-site",
        "password": "$(ww_reality_password)",
        "algorithm": "chacha20-poly1305",
        "salt": "waterwall-reality",
        "kdf-iterations": 12000
      },
      "next": "udp-over-tcp-server"
    },
    {
      "name": "cover-site",
      "type": "TcpConnector",
      "settings": {
        "address": "${WW_COVER:?missing WW_COVER}",
        "port": ${WW_COVER_PORT:-443},
        "nodelay": true
      }
    },
    {
      "name": "udp-over-tcp-server",
      "type": "UdpOverTcpServer",
      "settings": {},
      "next": "local-wireguard"
    },
    {
      "name": "local-wireguard",
      "type": "UdpConnector",
      "settings": { "address": "$thost", "port": $tport }
    }
  ]
}
EOF
                ;;
        esac
    fi
    chmod 644 "$out"
    # Fail fast on malformed JSON instead of leaving a broken tunnel behind.
    if have python3; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" \
            || die "Generated an invalid JSON file: $out"
    fi
    ok "wrote $out"
}

# --------------------------------------------------------------- service ----
ww_write_systemd() {
    cat > /etc/systemd/system/waterwall.service <<EOF
[Unit]
Description=WaterWall tunnel core ($WW_MODE)
Documentation=https://github.com/radkesvat/WaterWall
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$WW_ETC
ExecStart=$WW_OPT/Waterwall --config:$WW_ETC/core.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/waterwall.service
    systemctl daemon-reload
}

ww_apply() {
    log "Starting the WaterWall tunnel"
    systemctl enable waterwall.service >/dev/null 2>&1 || true
    systemctl restart waterwall.service
    if ! wait_service waterwall.service 12; then
        service_dump waterwall.service
        die "waterwall.service failed to start - see the log above."
    fi
    ok "waterwall.service is running"
    if [[ -f "$WW_LOG/core.log" ]]; then
        if grep -qiE 'error|failed|invalid' "$WW_LOG/core.log" 2>/dev/null; then
            warn "The WaterWall core log contains errors, check $WW_LOG/core.log"
        fi
    fi
}
