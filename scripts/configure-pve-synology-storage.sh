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
_SYNO_CONF_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SYNO_NFS_PROVISIONER="${_SYNO_CONF_SCRIPT_DIR}/synology-dsm-nfs-provision.py"

default_ipv4_for_nfs_client() {
  local target=$1 ip
  ip=$(ip -4 route get "$target" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  [[ -n "${ip}" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-}"
}

prompt_dsm_api_login() {
  prompt_line "DSM username (administrator account for API):" ""
  [[ -n ${REPLY:-} ]] || die "DSM username is required"
  syno_api_user=$REPLY
  prompt_secret "DSM password: "
  [[ -n ${REPLY:-} ]] || die "DSM password is required"
  syno_api_pass=$REPLY
  prompt_secret "Confirm DSM password: "
  [[ -n ${REPLY:-} ]] || die "password confirmation is required"
  [[ "${REPLY}" == "${syno_api_pass}" ]] || die "passwords do not match"
}

build_dsm_base_url() {
  local host=$1
  if prompt_yesno "Use HTTPS for DSM Web API?" y; then
    syno_api_https=y
    prompt_yesno "Verify DSM TLS certificate (disable for self-signed certs)?" n && syno_api_check_ssl=y || syno_api_check_ssl=n
    prompt_line "DSM HTTPS port [5001]:" "5001"
    syno_api_port=$REPLY
    syno_api_base_url="https://${host}:${syno_api_port}"
  else
    syno_api_https=n
    syno_api_check_ssl=n
    prompt_line "DSM HTTP port [5000]:" "5000"
    syno_api_port=$REPLY
    syno_api_base_url="http://${host}:${syno_api_port}"
  fi
  prompt_line "DSM Auth session name (optional; leave empty unless login fails without it):" ""
  syno_api_session=$REPLY
}

print_synology_nfs_dsm_steps() {
  local folder_name=$1
  local export_path=$2
  local server=$3
  cat <<EOF

--- Synology DSM: create the share and NFS export ---
1) Control Panel → Shared Folder → Create
   - Name: ${folder_name}
   - (Optional) Set a description such as "Proxmox NFS"
2) After it exists: select the folder → Edit → NFS Permissions → Create
   - Hostname or IP: your Proxmox node IP (or a trusted subnet)
   - Privilege: read/write
   - Squash: typically "Map all users to admin" or match your security model
   - Security: sys (default on many units)
3) Ensure NFS is enabled: Control Panel → File Services → NFS (enable if prompted).

Proxmox needs the export path that DSM shows for NFS (often: ${export_path}).
From this node you can list exports after NFS is enabled:
  pvesm scan nfs ${server}
---
EOF
}

# Proxmox nfs content: ISOs, CT templates, CT root volumes (adjust in the prompt if you want VM disks too).
readonly DEFAULT_NFS_CONTENT="iso,vztmpl,rootdir"

append_csv_unique() {
  local base=$1
  local add=$2
  local out
  out=$base
  if [[ ",${base}," != *",${add},"* ]]; then
    [[ -n "${out}" ]] && out+=","
    out+="${add}"
  fi
  printf '%s' "$out"
}

configure_nfs_synology_storage() {
  local storage_id nfs_server nfs_export syno_folder_name syno_vol_prefix nfs_content nfs_options nfs_path
  local nfs_client_ip default_cip syno_api_user syno_api_pass syno_api_base_url syno_api_port
  local syno_api_https syno_api_check_ssl syno_api_session py_cmd

  echo "NFS storage (standard Proxmox 'nfs' type; Synology exports a Shared Folder over NFS)."
  echo "No Synology Perl plugin is required for this path."
  echo

  prompt_line "Storage ID (short name in Proxmox, e.g. synology-nfs):" ""
  [[ -n ${REPLY:-} ]] || die "storage ID is required"
  storage_id=$REPLY
  if ! [[ $storage_id =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    die "storage ID must start with alphanumeric and contain only letters, digits, . _ -"
  fi

  if pvesm status "$storage_id" &>/dev/null; then
    die "storage '$storage_id' already exists — remove it first (pvesm remove $storage_id) or pick another ID"
  fi

  prompt_line "Synology hostname or IP for NFS (server= in Proxmox, no protocol):" ""
  [[ -n ${REPLY:-} ]] || die "server address is required"
  nfs_server=$REPLY

  default_cip=$(default_ipv4_for_nfs_client "$nfs_server")
  prompt_line "This Proxmox host IP for Synology NFS client rules (DSM) [${default_cip}]:" "${default_cip}"
  nfs_client_ip=$REPLY
  [[ -n "${nfs_client_ip}" ]] || die "client IP is required"

  echo
  if prompt_yesno "Do you need to create a new shared folder on the Synology for this NFS export?" y; then
    prompt_line "New shared folder name (DSM name, e.g. proxmox-data):" ""
    [[ -n ${REPLY:-} ]] || die "folder name is required"
    if ! [[ ${REPLY} =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      die "folder name must start with alphanumeric and use only letters, digits, . _ -"
    fi
    syno_folder_name=$REPLY
    prompt_line "Volume directory on the NAS that will hold this folder [/volume1]:" "/volume1"
    syno_vol_prefix=$REPLY
    [[ -n "${syno_vol_prefix}" ]] || die "volume path is required"
    syno_vol_prefix="${syno_vol_prefix%/}"
    nfs_export="${syno_vol_prefix}/${syno_folder_name}"

    if prompt_yesno "Create the folder and NFS permission via DSM Web API (uses username/password)?" y; then
      command -v python3 >/dev/null 2>&1 || die "python3 is required on this node for DSM API provisioning"
      [[ -f "${SYNO_NFS_PROVISIONER}" ]] || die "missing ${SYNO_NFS_PROVISIONER} (reinstall or copy from the plugin repo)"
      prompt_dsm_api_login
      build_dsm_base_url "$nfs_server"
      py_cmd=(
        python3 "${SYNO_NFS_PROVISIONER}"
        --base-url "${syno_api_base_url}"
        --account "${syno_api_user}"
        --password "${syno_api_pass}"
        --share-name "${syno_folder_name}"
        --vol-path "${syno_vol_prefix}"
        --client-host "${nfs_client_ip}"
      )
      [[ -n "${syno_api_session}" ]] && py_cmd+=(--session "${syno_api_session}")
      [[ "${syno_api_check_ssl}" != y ]] && py_cmd+=(--insecure-tls)
      echo
      echo "Calling Synology DSM API to create the share and allow NFS from ${nfs_client_ip}..."
      if ! "${py_cmd[@]}"; then
        die "DSM API provisioning failed. Fix credentials or use the manual steps below, then re-run this script."
      fi
      echo "DSM API provisioning finished."
    else
      print_synology_nfs_dsm_steps "$syno_folder_name" "$nfs_export" "$nfs_server"
      echo
      read_tty -p "Press Enter when the folder exists, NFS is enabled, and the export is ready..." _
    fi
  else
    prompt_line "NFS export path (as from 'pvesm scan nfs', e.g. /volume1/existing-share):" ""
    [[ -n ${REPLY:-} ]] || die "export path is required"
    nfs_export=$REPLY

    if prompt_yesno "Add an NFS permission rule for ${nfs_client_ip} via DSM Web API (existing share)?" n; then
      command -v python3 >/dev/null 2>&1 || die "python3 is required for DSM API provisioning"
      [[ -f "${SYNO_NFS_PROVISIONER}" ]] || die "missing ${SYNO_NFS_PROVISIONER}"
      prompt_line "DSM shared folder name (name in Control Panel → Shared Folder, not the full path):" ""
      [[ -n ${REPLY:-} ]] || die "shared folder name is required"
      syno_folder_name=$REPLY
      prompt_dsm_api_login
      build_dsm_base_url "$nfs_server"
      py_cmd=(
        python3 "${SYNO_NFS_PROVISIONER}"
        --base-url "${syno_api_base_url}"
        --account "${syno_api_user}"
        --password "${syno_api_pass}"
        --share-name "${syno_folder_name}"
        --client-host "${nfs_client_ip}"
        --privilege-only
      )
      [[ -n "${syno_api_session}" ]] && py_cmd+=(--session "${syno_api_session}")
      [[ "${syno_api_check_ssl}" != y ]] && py_cmd+=(--insecure-tls)
      echo
      echo "Calling DSM API to add NFS permission for ${nfs_client_ip}..."
      if ! "${py_cmd[@]}"; then
        die "DSM API failed. Add NFS permission manually in DSM for this share, then re-run."
      fi
    fi
  fi

  prompt_line "Proxmox content types (comma-separated):" "${DEFAULT_NFS_CONTENT}"
  [[ -n ${REPLY:-} ]] || die "content is required"
  nfs_content=$REPLY

  if prompt_yesno "Also use this storage for backups (vzdump / backup content type)?" n; then
    nfs_content=$(append_csv_unique "$nfs_content" "backup")
  fi

  nfs_path="/mnt/pve/${storage_id}"
  nfs_options="vers=3"
  echo
  echo "Default NFS mount options: vers=3 (recommended for Synology)."
  if prompt_yesno "Use custom NFS mount options instead (e.g. vers=4.1,soft)?" n; then
    prompt_line "NFS options (empty = let Proxmox use its default, no vers=3):" ""
    nfs_options=$REPLY
  fi

  echo
  if prompt_yesno "Run 'pvesm scan nfs' on ${nfs_server} now (lists exports the node can see)?" y; then
    pvesm scan nfs "$nfs_server" || true
    echo
  fi

  cmd=(pvesm add nfs "$storage_id")
  cmd+=(--server "$nfs_server")
  cmd+=(--export "$nfs_export")
  cmd+=(--path "$nfs_path")
  cmd+=(--content "$nfs_content")
  [[ -n "${nfs_options}" ]] && cmd+=(--options "$nfs_options")

  echo "Command to run:"
  i=0
  while ((i < ${#cmd[@]})); do
    printf ' %q' "${cmd[i]}"
    i=$((i + 1))
  done
  echo
  echo

  if [[ -n ${DRY_RUN:-} ]]; then
    echo "DRY_RUN is set — not executing pvesm."
    exit 0
  fi

  if ! prompt_yesno "Add this NFS storage now?" y; then
    echo "Aborted — no storage was added."
    exit 0
  fi

  set +e
  "${cmd[@]}"
  pvesm_rc=$?
  set -e
  if [[ $pvesm_rc -ne 0 ]]; then
    die "pvesm add nfs failed (exit $pvesm_rc). Check: export path matches 'pvesm scan nfs ${nfs_server}', DSM NFS rule for ${nfs_client_ip}, firewall, and storage ID spelling."
  fi

  if [[ ! -r /etc/pve/storage.cfg ]] || ! grep -Fx "nfs: $storage_id" /etc/pve/storage.cfg >/dev/null 2>&1; then
    die "pvesm reported success but there is no 'nfs: $storage_id' line in /etc/pve/storage.cfg — check cluster/pmxcfs health."
  fi

  if ! pvesm status "$storage_id" &>/dev/null; then
    die "Storage '${storage_id}' was added but is not online (mount failed). Try: pvesm remove ${storage_id}; confirm 'pvesm scan nfs ${nfs_server}' lists '${nfs_export}'; add DSM NFS permission for ${nfs_client_ip}; try custom options (e.g. vers=4.1). Check storage ID spelling (typos show as a separate pool name)."
  fi

  echo
  echo "Done. Check: pvesm status $storage_id"
  exit 0
}

echo "Proxmox + Synology storage — choose backend"
echo "  1) iSCSI via Synology plugin (pvesm type 'synology') — requires a DSM iSCSI target"
echo "  2) NFS from a Synology shared folder (pvesm type 'nfs') — standard Proxmox NFS storage"
echo
read_tty -p "Select [1/2] (default 1): " REPLY
storage_backend_choice=$(trim "${REPLY:-}")
[[ -z "${storage_backend_choice}" ]] && storage_backend_choice=1

case "${storage_backend_choice}" in
2)
  configure_nfs_synology_storage
  ;;
1)
  ;;
*)
  die "invalid choice — enter 1 or 2"
  ;;
esac

[[ -f "${SYNOLOGY_PLUGIN_PM}" ]] || die "Synology plugin not installed (missing ${SYNOLOGY_PLUGIN_PM}). Install SynologyStoragePlugin.pm, then restart pvedaemon, pvestatd, and pveproxy (see README Install). Without it, pvesm cannot add type 'synology' and storage.cfg will not change."

echo
echo "Synology iSCSI (plugin) — interactive configuration"
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
[[ -n "${debug_lvl}" ]] && cmd+=(--synology-debug "$debug_lvl")

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
