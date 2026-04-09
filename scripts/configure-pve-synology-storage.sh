#!/bin/bash
# Interactive helper: add Synology iSCSI storage to Proxmox via pvesm.
# Run on a PVE node as root after the Synology plugin is installed.
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

die() {
  echo "$SCRIPT_NAME: $*" >&2
  exit 1
}

trap 'echo "$SCRIPT_NAME: command failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Prefer the controlling tty so prompts work even when stdin is redirected; avoids stray EOF / set -u surprises.
read_tty() {
  if [[ -r /dev/tty ]]; then
    read -r "$@" < /dev/tty || true
  else
    read -r "$@" || true
  fi
}

# Reads one line into REPLY; optional default when empty.
prompt_line() {
  local msg=$1
  local default=${2-}
  if [[ -n "${default}" ]]; then
    read_tty -p "$msg [$default] " REPLY
    REPLY=$(trim "${REPLY:-}")
    # Not "[[ -z ... ]] && ..." — with set -e, a false [[ inside a function aborts the script.
    if [[ -z "${REPLY:-}" ]]; then
      REPLY=$default
    fi
  else
    read_tty -p "$msg " REPLY
    REPLY=$(trim "${REPLY:-}")
  fi
}

prompt_secret() {
  local msg=$1
  if [[ -r /dev/tty ]]; then
    read -r -s -p "$msg" REPLY < /dev/tty || true
  else
    read -r -s -p "$msg" REPLY || true
  fi
  # Newline on stderr so a closed/redirected stdout cannot SIGPIPE-kill the script (set -e).
  echo >&2
  REPLY=$(trim "${REPLY:-}")
}

# y -> yes, n -> no, default when empty.
prompt_yesno() {
  local msg=$1
  local def=$2 # y or n
  local hint
  [[ "${def}" == y ]] && hint="[Y/n]" || hint="[y/N]"
  read_tty -p "$msg $hint " REPLY
  REPLY=$(trim "${REPLY:-}")
  if [[ -z "${REPLY:-}" ]]; then
    REPLY=$def
  fi
  case "${REPLY,,}" in
  y|yes) return 0 ;;
  n|no) return 1 ;;
  *)
    [[ "${def}" == y ]] && return 0 || return 1
    ;;
  esac
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "run as root (e.g. sudo $SCRIPT_NAME)"
fi

command -v pvesm >/dev/null 2>&1 || die "pvesm not found — run this on a Proxmox VE node"

readonly SYNOLOGY_PLUGIN_PM="/usr/share/perl5/PVE/Storage/Custom/SynologyStoragePlugin.pm"
[[ -f "${SYNOLOGY_PLUGIN_PM}" ]] || die "Synology plugin not installed (missing ${SYNOLOGY_PLUGIN_PM}). Install SynologyStoragePlugin.pm, then restart pvedaemon, pvestatd, and pveproxy (see README Install). Without it, pvesm cannot add type 'synology' and storage.cfg will not change."

echo "Proxmox Synology storage — interactive configuration"
echo "A pre-created iSCSI target on DSM must exist; its name must match what you enter below."
echo

prompt_line "Storage ID (short name in Proxmox, e.g. synology-nas):" ""
[[ -n ${REPLY:-} ]] || die "storage ID is required"
storage_id=$REPLY
if ! [[ $storage_id =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  die "storage ID must start with alphanumeric and contain only letters, digits, . _ -"
fi

if pvesm status "$storage_id" &>/dev/null; then
  die "storage '$storage_id' already exists — remove it first (pvesm remove $storage_id) or pick another ID"
fi

prompt_line "Synology DSM hostname or IP (no https://):" ""
[[ -n ${REPLY:-} ]] || die "address is required"
address=$REPLY

prompt_line "DSM username:" ""
[[ -n ${REPLY:-} ]] || die "username is required"
username=$REPLY

prompt_secret "DSM password: "
[[ -n ${REPLY:-} ]] || die "password is required"
password=$REPLY

prompt_secret "Confirm DSM password: "
[[ -n ${REPLY:-} ]] || die "password confirmation is required"
[[ "${REPLY}" == "${password}" ]] || die "passwords do not match"

prompt_line "Existing iSCSI target name (exactly as in DSM SAN Manager):" ""
[[ -n ${REPLY:-} ]] || die "target name is required"
target_name=$REPLY

prompt_line "LUN location on the NAS (where DSM stores LUNs):" "/volume1"
lun_location=$REPLY
[[ -n "${lun_location}" ]] || die "LUN location is required"

prompt_line "Proxmox content types (comma-separated, usually images):" "images"
content=$REPLY
[[ -n "${content}" ]] || die "content is required"

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
  echo
  if prompt_yesno "Use HTTPS for DSM API?" y; then
    use_https=yes
  else
    use_https=no
  fi

  prompt_line "DSM API port (Enter for default: 5001 HTTPS / 5000 HTTP):" ""
  dsm_port=$REPLY

  if prompt_yesno "Verify DSM TLS certificate (use only with a proper cert)?" n; then
    check_ssl=yes
  else
    check_ssl=no
  fi

  prompt_line "LUN type (Enter for plugin default THIN, e.g. THIN BLUN FILE):" ""
  lun_type=$REPLY

  prompt_line "Optional LUN name prefix on Synology (vnprefix):" ""
  vnprefix=$REPLY

  if prompt_yesno "Run iSCSI sendtargets/login on storage activate?" y; then
    auto_iscsi=yes
  else
    auto_iscsi=no
  fi

  prompt_line "iSCSI discovery portals (comma-separated host or host:port; Enter to use ${address}:3260):" ""
  iscsi_discovery_ips=$REPLY

  prompt_line "iSCSI target port (Enter for 3260):" ""
  iscsi_port=$REPLY

  prompt_line "DSM session name for SYNO.API.Auth if login fails (dsm_session, often empty):" ""
  dsm_session=$REPLY

  prompt_line "Minimum max iSCSI sessions on target (Enter for plugin default 32):" ""
  max_iscsi=$REPLY

  prompt_line "Debug level 0–3 (Enter for 0):" ""
  debug_lvl=$REPLY
fi

cmd=(pvesm add synology "$storage_id")
cmd+=(--address "$address")
cmd+=(--username "$username")
cmd+=(--password "$password")
cmd+=(--target_name "$target_name")
cmd+=(--lun_location "$lun_location")
cmd+=(--content "$content")
cmd+=(--use_https "$use_https")
cmd+=(--check_ssl "$check_ssl")
cmd+=(--auto_iscsi_discovery "$auto_iscsi")

[[ -n "${dsm_port}" ]] && cmd+=(--dsm_port "$dsm_port")
[[ -n "${lun_type}" ]] && cmd+=(--lun_type "$lun_type")
[[ -n "${vnprefix}" ]] && cmd+=(--vnprefix "$vnprefix")
[[ -n "${iscsi_discovery_ips}" ]] && cmd+=(--iscsi_discovery_ips "$iscsi_discovery_ips")
[[ -n "${iscsi_port}" ]] && cmd+=(--iscsi_port "$iscsi_port")
[[ -n "${dsm_session}" ]] && cmd+=(--dsm_session "$dsm_session")
[[ -n "${max_iscsi}" ]] && cmd+=(--max_iscsi_sessions "$max_iscsi")
[[ -n "${debug_lvl}" ]] && cmd+=(--debug "$debug_lvl")

echo
echo "Command to run (password shown as ***):"
i=0
while ((i < ${#cmd[@]})); do
  if [[ ${cmd[i]} == --password ]]; then
    printf ' %q %q' "${cmd[i]}" "***"
    i=$((i + 2))
  else
    printf ' %q' "${cmd[i]}"
    i=$((i + 1))
  fi
done
echo
echo

if [[ -n ${DRY_RUN:-} ]]; then
  echo "DRY_RUN is set — not executing pvesm."
  exit 0
fi

if ! prompt_yesno "Add this storage now?" y; then
  echo "Aborted — no storage was added. /etc/pve/storage.cfg is unchanged. Re-run when ready, or run the quoted command above yourself."
  exit 0
fi

set +e
"${cmd[@]}"
pvesm_rc=$?
set -e
if [[ $pvesm_rc -ne 0 ]]; then
  die "pvesm add failed (exit $pvesm_rc). If the error mentions an unknown storage type, install $SYNOLOGY_PLUGIN_PM and restart pvedaemon/pvestatd/pveproxy, then try again."
fi

if [[ ! -r /etc/pve/storage.cfg ]] || ! grep -Fx "synology: $storage_id" /etc/pve/storage.cfg >/dev/null 2>&1; then
  die "pvesm reported success but there is no 'synology: $storage_id' line in /etc/pve/storage.cfg — check cluster/pmxcfs health and permissions on /etc/pve."
fi

if ! pvesm status "$storage_id" &>/dev/null; then
  die "storage stanza may exist but pvesm status '$storage_id' failed — check pvesm output and journal."
fi

echo
echo "Done. Check: pvesm status $storage_id"
