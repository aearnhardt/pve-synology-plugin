#!/bin/bash
# Install SynologyStoragePlugin.pm onto a Proxmox VE node.
set -euo pipefail

# REPO_BASE = raw.githubusercontent.com prefix including branch (e.g. .../pve-synology-plugin/main).
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main}"
PLUGIN_URL="${PLUGIN_URL:-${REPO_BASE}/SynologyStoragePlugin.pm}"

DEST="${DEST:-/usr/share/perl5/PVE/Storage/Custom/SynologyStoragePlugin.pm}"
TMP="${TMP:-$(mktemp)}"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "Fetching ${PLUGIN_URL}"
curl -fsSL -o "$TMP" "$PLUGIN_URL"

install -d -m 0755 "$(dirname "$DEST")"
install -m 0644 "$TMP" "$DEST"
echo "Installed $DEST"

restart_pve_stack() {
  local cmd
  if command -v deb-systemd-invoke >/dev/null 2>&1; then
    cmd=(deb-systemd-invoke)
  else
    cmd=(systemctl)
  fi
  "${cmd[@]}" try-restart pve-cluster.service 2>/dev/null || true
  "${cmd[@]}" try-restart pvedaemon.service 2>/dev/null || true
  "${cmd[@]}" try-restart pvestatd.service 2>/dev/null || true
  "${cmd[@]}" try-restart pveproxy.service 2>/dev/null || true
  "${cmd[@]}" try-restart pvescheduler.service 2>/dev/null || true
}

if [[ -d /run/systemd/system ]]; then
  restart_pve_stack
  echo "Triggered try-restart of pve-cluster, pvedaemon, pvestatd, pveproxy, pvescheduler (if present)."
fi
