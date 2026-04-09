#!/bin/bash
# Unified installer for the Proxmox Synology plugin.
# - Installs SynologyStoragePlugin.pm onto a PVE node
# - Optionally launches interactive storage configuration via pvesm
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SYNOLOGY_PLUGIN_PM="/usr/share/perl5/PVE/Storage/Custom/SynologyStoragePlugin.pm"

die() {
  echo "$SCRIPT_NAME: $*" >&2
  exit 1
}

info() {
  echo "$SCRIPT_NAME: $*"
}

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Options:
  --repo-base URL        Base raw GitHub URL for repository content
                         Default: https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main
  --plugin-url URL       Full URL to SynologyStoragePlugin.pm (overrides --repo-base)
  --dest PATH            Plugin destination path
                         Default: /usr/share/perl5/PVE/Storage/Custom/SynologyStoragePlugin.pm
  --configure            Prompt to configure Synology storage after install (default)
  --no-configure         Skip storage configuration
  --menu                 Force interactive main menu
  --no-menu              Disable interactive main menu
  --yes, -y              Non-interactive; assume yes for prompts
  --help, -h             Show this help

Environment overrides:
  REPO_BASE, PLUGIN_URL, DEST, DRY_RUN
EOF
}

pause_prompt() {
  if [[ -t 0 ]]; then
    read_tty -p "Press Enter to continue..." REPLY
  fi
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

read_tty() {
  if [[ -r /dev/tty ]]; then
    read -r "$@" < /dev/tty || true
  else
    read -r "$@" || true
  fi
}

prompt_yesno() {
  local msg=$1
  local def=$2 # y or n
  local hint
  [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
  read_tty -p "$msg $hint " REPLY
  REPLY=$(trim "${REPLY:-}")
  if [[ -z "${REPLY:-}" ]]; then
    REPLY=$def
  fi
  case "${REPLY,,}" in
    y|yes) return 0 ;;
    n|no) return 1 ;;
    *) [[ "$def" == y ]] ;;
  esac
}

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

install_plugin() {
  local plugin_url=$1
  local dest=$2
  local local_candidate="./SynologyStoragePlugin.pm"

  if [[ -f "$local_candidate" && -z "${PLUGIN_URL:-}" ]]; then
    info "Using local plugin file: ${local_candidate}"
    if [[ -n "${DRY_RUN:-}" ]]; then
      info "DRY_RUN is set - would install ${local_candidate} to ${dest}"
    else
      install -d -m 0755 "$(dirname "$dest")"
      install -m 0644 "$local_candidate" "$dest"
      info "Installed $dest"
    fi
  else
    local tmp
    tmp="$(mktemp)"
    cleanup_tmp() { rm -f "$tmp"; }
    trap cleanup_tmp RETURN

    info "Fetching ${plugin_url}"
    curl -fsSL -o "$tmp" "$plugin_url"

    if [[ -n "${DRY_RUN:-}" ]]; then
      info "DRY_RUN is set - would install to ${dest}"
    else
      install -d -m 0755 "$(dirname "$dest")"
      install -m 0644 "$tmp" "$dest"
      info "Installed $dest"
    fi
  fi

  if [[ -d /run/systemd/system ]]; then
    restart_pve_stack
    info "Triggered try-restart of pve-cluster, pvedaemon, pvestatd, pveproxy, pvescheduler."
  fi
}

uninstall_plugin() {
  local dest=$1
  if [[ ! -e "$dest" ]]; then
    info "Plugin file not present at ${dest}"
    return 0
  fi

  if [[ -n "${DRY_RUN:-}" ]]; then
    info "DRY_RUN is set - would remove ${dest}"
    return 0
  fi

  rm -f "$dest"
  info "Removed ${dest}"
  if [[ -d /run/systemd/system ]]; then
    restart_pve_stack
    info "Triggered service try-restarts after uninstall."
  fi
}

show_status() {
  local dest=$1
  if [[ -f "$dest" ]]; then
    info "Plugin installed at ${dest}"
  else
    info "Plugin NOT installed at ${dest}"
  fi

  if command -v pvesm >/dev/null 2>&1; then
    echo
    pvesm status || true
  else
    info "pvesm not found on this host."
  fi
}

show_main_menu() {
  local plugin_url=$1
  local dest=$2

  while true; do
    echo
    echo "==== Proxmox Synology Plugin Installer ===="
    echo "1) Install plugin (prefer local ./SynologyStoragePlugin.pm)"
    echo "2) Configure Synology storage (pvesm add synology)"
    echo "3) Install plugin + configure storage"
    echo "4) Reinstall plugin from remote URL"
    echo "5) Show install/storage status"
    echo "6) Uninstall plugin"
    echo "7) Exit"
    echo
    read_tty -p "Select an option [1-7]: " REPLY
    local choice
    choice=$(trim "${REPLY:-}")

    case "$choice" in
      1)
        install_plugin "$plugin_url" "$dest"
        pause_prompt
        ;;
      2)
        configure_storage
        pause_prompt
        ;;
      3)
        install_plugin "$plugin_url" "$dest"
        configure_storage
        pause_prompt
        ;;
      4)
        local no_local_plugin_backup=${PLUGIN_URL:-}
        PLUGIN_URL="$plugin_url"
        install_plugin "$plugin_url" "$dest"
        PLUGIN_URL="$no_local_plugin_backup"
        pause_prompt
        ;;
      5)
        show_status "$dest"
        pause_prompt
        ;;
      6)
        if prompt_yesno "Remove plugin file from ${dest}?" n; then
          uninstall_plugin "$dest"
        fi
        pause_prompt
        ;;
      7)
        info "Exiting."
        break
        ;;
      *)
        info "Invalid selection."
        ;;
    esac
  done
}

configure_storage() {
  command -v pvesm >/dev/null 2>&1 || die "pvesm not found - run this on a Proxmox VE node"
  [[ -f "$SYNOLOGY_PLUGIN_PM" ]] || die "plugin not installed at $SYNOLOGY_PLUGIN_PM"

  info "Proxmox Synology storage - interactive configuration"
  info "A pre-created iSCSI target on DSM must exist."
  echo

  local storage_id address username password confirm_password
  local target_name lun_location content use_https check_ssl
  local dsm_port lun_type iscsi_discovery_ips auto_iscsi
  local iscsi_port dsm_session vnprefix max_iscsi debug_lvl

  read_tty -p "Storage ID (e.g. synology-nas): " REPLY
  storage_id=$(trim "${REPLY:-}")
  [[ -n "$storage_id" ]] || die "storage ID is required"
  [[ "$storage_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid storage ID format"
  if pvesm status "$storage_id" &>/dev/null; then
    die "storage '$storage_id' already exists"
  fi

  read_tty -p "Synology DSM hostname or IP (no https://): " REPLY
  address=$(trim "${REPLY:-}")
  [[ -n "$address" ]] || die "address is required"

  read_tty -p "DSM username: " REPLY
  username=$(trim "${REPLY:-}")
  [[ -n "$username" ]] || die "username is required"

  if [[ -r /dev/tty ]]; then
    read -r -s -p "DSM password: " REPLY < /dev/tty || true
  else
    read -r -s -p "DSM password: " REPLY || true
  fi
  echo >&2
  password=$(trim "${REPLY:-}")
  [[ -n "$password" ]] || die "password is required"

  if [[ -r /dev/tty ]]; then
    read -r -s -p "Confirm DSM password: " REPLY < /dev/tty || true
  else
    read -r -s -p "Confirm DSM password: " REPLY || true
  fi
  echo >&2
  confirm_password=$(trim "${REPLY:-}")
  [[ -n "$confirm_password" ]] || die "password confirmation is required"
  [[ "$confirm_password" == "$password" ]] || die "passwords do not match"

  read_tty -p "Existing iSCSI target name (exactly as in DSM): " REPLY
  target_name=$(trim "${REPLY:-}")
  [[ -n "$target_name" ]] || die "target name is required"

  read_tty -p "LUN location on NAS [/volume1]: " REPLY
  lun_location=$(trim "${REPLY:-}")
  [[ -z "$lun_location" ]] && lun_location="/volume1"

  read_tty -p "Proxmox content types [images]: " REPLY
  content=$(trim "${REPLY:-}")
  [[ -z "$content" ]] && content="images"

  use_https=yes
  check_ssl=no
  dsm_port=""
  lun_type=""
  iscsi_discovery_ips=""
  auto_iscsi=yes
  iscsi_port=""
  dsm_session=""
  vnprefix=""
  max_iscsi=""
  debug_lvl=""

  if prompt_yesno "Configure optional / advanced settings?" n; then
    prompt_yesno "Use HTTPS for DSM API?" y && use_https=yes || use_https=no

    read_tty -p "DSM API port (default: 5001 HTTPS / 5000 HTTP): " REPLY
    dsm_port=$(trim "${REPLY:-}")

    prompt_yesno "Verify DSM TLS certificate?" n && check_ssl=yes || check_ssl=no

    read_tty -p "LUN type (default THIN; e.g. THIN BLUN FILE): " REPLY
    lun_type=$(trim "${REPLY:-}")

    read_tty -p "Optional LUN name prefix (vnprefix): " REPLY
    vnprefix=$(trim "${REPLY:-}")

    prompt_yesno "Run iSCSI discovery/login on activate?" y && auto_iscsi=yes || auto_iscsi=no

    read_tty -p "iSCSI discovery portals (comma-separated, default ${address}:3260): " REPLY
    iscsi_discovery_ips=$(trim "${REPLY:-}")

    read_tty -p "iSCSI target port (default 3260): " REPLY
    iscsi_port=$(trim "${REPLY:-}")

    read_tty -p "DSM session name (dsm_session): " REPLY
    dsm_session=$(trim "${REPLY:-}")

    read_tty -p "Minimum max iSCSI sessions (default 32): " REPLY
    max_iscsi=$(trim "${REPLY:-}")

    read_tty -p "Debug level 0-3 (default 0): " REPLY
    debug_lvl=$(trim "${REPLY:-}")
  fi

  local cmd=(pvesm add synology "$storage_id")
  cmd+=(--address "$address")
  cmd+=(--username "$username")
  cmd+=(--password "$password")
  cmd+=(--target_name "$target_name")
  cmd+=(--lun_location "$lun_location")
  cmd+=(--content "$content")
  cmd+=(--use_https "$use_https")
  cmd+=(--check_ssl "$check_ssl")
  cmd+=(--auto_iscsi_discovery "$auto_iscsi")

  [[ -n "$dsm_port" ]] && cmd+=(--dsm_port "$dsm_port")
  [[ -n "$lun_type" ]] && cmd+=(--lun_type "$lun_type")
  [[ -n "$vnprefix" ]] && cmd+=(--vnprefix "$vnprefix")
  [[ -n "$iscsi_discovery_ips" ]] && cmd+=(--iscsi_discovery_ips "$iscsi_discovery_ips")
  [[ -n "$iscsi_port" ]] && cmd+=(--iscsi_port "$iscsi_port")
  [[ -n "$dsm_session" ]] && cmd+=(--dsm_session "$dsm_session")
  [[ -n "$max_iscsi" ]] && cmd+=(--max_iscsi_sessions "$max_iscsi")
  [[ -n "$debug_lvl" ]] && cmd+=(--synology-debug "$debug_lvl")

  echo
  info "Command to run (password masked):"
  local i=0
  while (( i < ${#cmd[@]} )); do
    if [[ "${cmd[i]}" == "--password" ]]; then
      printf ' %q %q' "${cmd[i]}" "***"
      i=$((i + 2))
    else
      printf ' %q' "${cmd[i]}"
      i=$((i + 1))
    fi
  done
  echo

  if [[ -n "${DRY_RUN:-}" ]]; then
    info "DRY_RUN is set - not executing pvesm."
    return 0
  fi

  if ! prompt_yesno "Add this storage now?" y; then
    info "Aborted - no storage was added."
    return 0
  fi

  set +e
  "${cmd[@]}"
  local pvesm_rc=$?
  set -e
  [[ $pvesm_rc -eq 0 ]] || die "pvesm add failed (exit $pvesm_rc)"

  if [[ ! -r /etc/pve/storage.cfg ]] || ! grep -Fx "synology: $storage_id" /etc/pve/storage.cfg >/dev/null 2>&1; then
    die "pvesm reported success, but storage.cfg does not contain 'synology: $storage_id'"
  fi

  pvesm status "$storage_id" >/dev/null 2>&1 || die "storage added, but pvesm status failed for '$storage_id'"
  info "Done. Check: pvesm status $storage_id"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "run as root (e.g. sudo $SCRIPT_NAME)"
fi

repo_base="${REPO_BASE:-https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main}"
plugin_url="${PLUGIN_URL:-}"
dest="${DEST:-$SYNOLOGY_PLUGIN_PM}"
configure_after_install=true
assume_yes=false
force_menu=false
disable_menu=false
saw_options=false

while (($#)); do
  saw_options=true
  case "$1" in
    --repo-base)
      (($# >= 2)) || die "--repo-base requires a value"
      repo_base="$2"
      shift 2
      ;;
    --plugin-url)
      (($# >= 2)) || die "--plugin-url requires a value"
      plugin_url="$2"
      shift 2
      ;;
    --dest)
      (($# >= 2)) || die "--dest requires a value"
      dest="$2"
      shift 2
      ;;
    --configure)
      configure_after_install=true
      shift
      ;;
    --no-configure)
      configure_after_install=false
      shift
      ;;
    --yes|-y)
      assume_yes=true
      shift
      ;;
    --menu)
      force_menu=true
      shift
      ;;
    --no-menu)
      disable_menu=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

if [[ -z "$plugin_url" ]]; then
  plugin_url="${repo_base%/}/SynologyStoragePlugin.pm"
fi

if [[ "$force_menu" == true ]]; then
  show_main_menu "$plugin_url" "$dest"
  exit 0
fi

if [[ "$disable_menu" == false && "$assume_yes" == false && "$saw_options" == false && -t 0 ]]; then
  show_main_menu "$plugin_url" "$dest"
  exit 0
fi

install_plugin "$plugin_url" "$dest"

if ! command -v pvesm >/dev/null 2>&1; then
  info "pvesm not found; skipping storage configuration."
  exit 0
fi

if [[ "$configure_after_install" == false ]]; then
  info "Skipping storage configuration (--no-configure)."
  exit 0
fi

if [[ "$assume_yes" == true ]]; then
  configure_storage
  exit 0
fi

if prompt_yesno "Configure Synology storage now?" y; then
  configure_storage
else
  info "Install complete. To configure later, run scripts/configure-pve-synology-storage.sh"
fi
