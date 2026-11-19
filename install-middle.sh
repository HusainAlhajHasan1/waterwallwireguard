#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-middle.sh (bootstrap)
#
# One-liner entry point for the MIDDLE server: run it on the Proxmox host as
# root. It downloads this repository and runs scripts/middle/install.sh.
#
#   WW_JOIN='<token from the exit server>' bash -c "$(curl -fsSL \
#     https://raw.githubusercontent.com/HusainAlhajHasan1/waterwallwireguard/main/install-middle.sh)"
#
# Environment:
#   WW_JOIN   join token printed by the exit installer (or pass --join TOKEN)
#   WW_REPO   owner/repo      (default HusainAlhajHasan1/waterwallwireguard)
#   WW_REF    branch or tag   (default main)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${WW_REPO:-HusainAlhajHasan1/waterwallwireguard}"
REF="${WW_REF:-main}"

if [[ "$REF" == refs/* || "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    REF_URL="$REF"
else
    REF_URL="refs/heads/$REF"
fi

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "tar is required" >&2;  exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching $REPO ($REF)"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
    "https://codeload.github.com/$REPO/tar.gz/$REF_URL" | tar -xz -C "$TMP" \
    || { echo "Could not download the repository (check WW_REPO / WW_REF)" >&2; exit 1; }

SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$SRC" ]] || { echo "Unexpected archive layout" >&2; exit 1; }

exec bash "$SRC/scripts/middle/install.sh" "$@"
