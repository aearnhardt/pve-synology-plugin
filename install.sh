#!/bin/bash
# Unified installer for the Proxmox Synology plugin.
# - Installs SynologyStoragePlugin.pm onto a PVE node
# - Optionally launches interactive storage configuration via pvesm
# - NFS + Synology DSM API provisioning is embedded (python3 stdlib only; no extra files)
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

default_ipv4_for_nfs_client() {
  local target=$1 ip
  ip=$(ip -4 route get "$target" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  [[ -n "${ip}" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-}"
}

nfs_prompt_dsm_api_login() {
  read_tty -p "DSM username (administrator account for API): " REPLY
  syno_api_user=$(trim "${REPLY:-}")
  [[ -n "$syno_api_user" ]] || die "DSM username is required"
  if [[ -r /dev/tty ]]; then
    read -r -s -p "DSM password: " REPLY < /dev/tty || true
  else
    read -r -s -p "DSM password: " REPLY || true
  fi
  echo >&2
  syno_api_pass=$(trim "${REPLY:-}")
  [[ -n "$syno_api_pass" ]] || die "DSM password is required"
  if [[ -r /dev/tty ]]; then
    read -r -s -p "Confirm DSM password: " REPLY < /dev/tty || true
  else
    read -r -s -p "Confirm DSM password: " REPLY || true
  fi
  echo >&2
  [[ "$(trim "${REPLY:-}")" == "$syno_api_pass" ]] || die "passwords do not match"
}

nfs_build_dsm_base_url() {
  local host=$1
  if prompt_yesno "Use HTTPS for DSM Web API?" y; then
    syno_api_https=y
    if prompt_yesno "Verify DSM TLS certificate (disable for self-signed certs)?" n; then
      syno_api_check_ssl=y
    else
      syno_api_check_ssl=n
    fi
    read_tty -p "DSM HTTPS port [5001]: " REPLY
    syno_api_port=$(trim "${REPLY:-}")
    [[ -z "$syno_api_port" ]] && syno_api_port=5001
    syno_api_base_url="https://${host}:${syno_api_port}"
  else
    syno_api_https=n
    syno_api_check_ssl=n
    read_tty -p "DSM HTTP port [5000]: " REPLY
    syno_api_port=$(trim "${REPLY:-}")
    [[ -z "$syno_api_port" ]] && syno_api_port=5000
    syno_api_base_url="http://${host}:${syno_api_port}"
  fi
  read_tty -p "DSM Auth session name (optional, empty unless login requires it): " REPLY
  syno_api_session=$(trim "${REPLY:-}")
}

# Embedded DSM Web API client (stdlib only). Keeps install.sh standalone — no extra files required.
run_synology_dsm_nfs_provision() {
  python3 - "$@" <<'INSTALL_SH_SYNOLOGY_NFS_PY_EOF'
from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


def _ctx(insecure: bool) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def api_get(
    base: str,
    path: str,
    params: dict[str, str],
    sid: str | None,
    insecure: bool,
    timeout: int = 120,
) -> dict:
    q = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    url = base.rstrip("/") + path + "?" + q
    req = urllib.request.Request(url)
    if sid:
        req.add_header("Cookie", f"id={sid}")
    with urllib.request.urlopen(req, context=_ctx(insecure), timeout=timeout) as r:
        body = r.read().decode("utf-8", errors="replace")
    return json.loads(body)


def api_entry(
    base: str,
    params: dict[str, str],
    sid: str | None,
    insecure: bool,
    *,
    use_post: bool,
    timeout: int = 120,
) -> dict:
    """Call /webapi/entry.cgi via GET or POST (form). SharePrivilege expects version 1 and usually POST."""
    url = base.rstrip("/") + "/webapi/entry.cgi"
    if use_post:
        body = urllib.parse.urlencode(params, quote_via=urllib.parse.quote).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    else:
        q = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        req = urllib.request.Request(url + "?" + q)
    if sid:
        req.add_header("Cookie", f"id={sid}")
    with urllib.request.urlopen(req, context=_ctx(insecure), timeout=timeout) as r:
        raw = r.read().decode("utf-8", errors="replace")
    return json.loads(raw)


def api_entry_json_method(
    base: str,
    api_name: str,
    version: int,
    method: str,
    params_obj: dict,
    sid: str | None,
    insecure: bool,
    *,
    synotoken: str = "",
    timeout: int = 120,
) -> dict:
    """
    JSON-format DSM APIs: api, version, method, _sid, SynoToken belong in the QUERY STRING;
    the POST body is ONLY the method-specific JSON object (see DSM Login Web API Guide).
    Putting api/method in the body yields error 101 (missing method).
    """
    q: dict[str, str] = {
        "api": api_name,
        "version": str(version),
        "method": method,
    }
    if sid:
        q["_sid"] = sid
    if synotoken:
        q["SynoToken"] = synotoken
    url = (
        base.rstrip("/")
        + "/webapi/entry.cgi?"
        + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)
    )
    raw_body = json.dumps(params_obj, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(url, data=raw_body, method="POST")
    req.add_header("Content-Type", "application/json; charset=utf-8")
    if sid:
        req.add_header("Cookie", f"id={sid}")
    with urllib.request.urlopen(req, context=_ctx(insecure), timeout=timeout) as r:
        raw = r.read().decode("utf-8", errors="replace")
    return json.loads(raw)


def login(
    base: str,
    account: str,
    passwd: str,
    session: str,
    insecure: bool,
) -> tuple[str, str]:
    params: dict[str, str] = {
        "api": "SYNO.API.Auth",
        "version": "3",
        "method": "login",
        "account": account,
        "passwd": passwd,
        "format": "sid",
        "enable_syno_token": "yes",
    }
    if session:
        params["session"] = session
    try:
        d = api_get(base, "/webapi/auth.cgi", params, None, insecure)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"DSM login HTTP {e.code}: {e.reason}") from e
    except urllib.error.URLError as e:
        raise SystemExit(f"DSM login connection failed: {e.reason}") from e
    if not d.get("success"):
        code = (d.get("error") or {}).get("code", "?")
        raise SystemExit(f"DSM login failed (API error code {code}): {json.dumps(d)}")
    sid = (d.get("data") or {}).get("sid")
    if not sid:
        raise SystemExit("DSM login returned no sid")
    synotoken = (d.get("data") or {}).get("synotoken") or ""
    return sid, synotoken


def share_create(
    base: str,
    sid: str,
    name: str,
    vol_path: str,
    desc: str,
    insecure: bool,
    synotoken: str = "",
) -> None:
    shareinfo = {
        "name": name,
        "vol_path": vol_path,
        "desc": desc,
        "enable_share_cow": False,
        "enable_recycle_bin": True,
        "recycle_bin_admin_only": False,
        "encryption": 0,
    }
    params = {
        "api": "SYNO.Core.Share",
        "version": "1",
        "method": "create",
        "name": json.dumps(name),
        "shareinfo": json.dumps(shareinfo, separators=(",", ":")),
    }
    if synotoken:
        params["SynoToken"] = synotoken
    d = api_get(base, "/webapi/entry.cgi", params, sid, insecure)
    if d.get("success"):
        return
    code = (d.get("error") or {}).get("code")
    # DSM: 3301 = same shared folder name exists; 3312 = same folder name on volume; 3319 = reserved/existed;
    # 1600 seen on some builds — all mean we can skip create and configure NFS only.
    if code in (1600, 3301, 3312, 3319):
        print(
            "install.sh (DSM API): shared folder already exists (create returned code "
            + str(code)
            + "); continuing to NFS permission step.",
            file=sys.stderr,
        )
        return
    raise SystemExit(f"SYNO.Core.Share create failed (code {code}): {json.dumps(d)}")


def nfs_service_enable_best_effort(
    base: str, sid: str, insecure: bool, synotoken: str = ""
) -> bool:
    attempts: list[dict[str, str]] = []
    for ver in ("3", "2", "1"):
        attempts.extend(
            [
                {
                    "api": "SYNO.Core.FileServ.NFS",
                    "version": ver,
                    "method": "set",
                    "enable_nfs": "true",
                },
                {
                    "api": "SYNO.Core.FileServ.NFS",
                    "version": ver,
                    "method": "set",
                    "nfs_enable": "true",
                },
                {
                    "api": "SYNO.Core.FileServ.NFS",
                    "version": ver,
                    "method": "set",
                    "enable_service": "true",
                },
            ]
        )
    for p in attempts:
        if synotoken:
            p = {**p, "SynoToken": synotoken}
        try:
            d = api_get(base, "/webapi/entry.cgi", p, sid, insecure)
        except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError, TimeoutError):
            continue
        if d.get("success"):
            return True
    return False


def share_list_find_share(
    base: str,
    sid: str,
    want_name: str,
    insecure: bool,
    synotoken: str = "",
) -> dict | None:
    """Resolve shared folder by name; DSM SharePrivilege often needs uuid/share_folder_id."""
    additional = json.dumps(["uuid", "name", "vol_path", "folder_uuid", "share_uuid"])
    for ver in ("2", "1"):
        params: dict[str, str] = {
            "api": "SYNO.Core.Share",
            "version": ver,
            "method": "list",
            "shareType": "all",
            "additional": additional,
        }
        if synotoken:
            params["SynoToken"] = synotoken
        try:
            d = api_get(base, "/webapi/entry.cgi", params, sid, insecure)
        except Exception:  # noqa: BLE001
            continue
        if not d.get("success"):
            continue
        shares = (d.get("data") or {}).get("shares") or []
        for s in shares:
            if isinstance(s, dict) and s.get("name", "").lower() == want_name.lower():
                return s
    return None


def _nfs_row_looks_nfs(row: dict) -> bool:
    if any(k in row for k in ("hostname", "host", "client", "ip", "allowed_host")):
        return True
    return bool("privilege" in row and ("squash" in row or "security" in row))


def _nfs_privilege_find_list(data: object) -> tuple[str, list] | None:
    if not isinstance(data, dict):
        return None
    empty_ok = frozenset({"nfs_share_list", "nfs_rules"})
    preferred = (
        "nfs_share_list",
        "nfs_rules",
        "share_privilege",
        "rules",
        "privilege_list",
        "nfs_hosts",
        "hosts",
        "clients",
        "entries",
        "items",
    )
    for key in preferred:
        val = data.get(key)
        if not isinstance(val, list):
            continue
        if not val:
            if key in empty_ok:
                return key, val
            continue
        if isinstance(val[0], dict) and _nfs_row_looks_nfs(val[0]):
            return key, val
    for key, val in data.items():
        if key in preferred:
            continue
        if not isinstance(val, list) or not val or not isinstance(val[0], dict):
            continue
        if _nfs_row_looks_nfs(val[0]):
            return key, val
    return None


def nfs_share_privilege_set(
    base: str,
    sid: str,
    share: str,
    client_host: str,
    insecure: bool,
    synotoken: str = "",
) -> None:
    """
    SharePrivilege v1: only load/save (103 on set/create). requestFormat JSON: put api/version/method/_sid
    in the query string and send method params as the JSON body; otherwise DSM returns 101.
    """
    sp_api = "SYNO.Core.FileServ.NFS.SharePrivilege"
    ver = "1"
    errors: list[str] = []

    def try_form(params: dict[str, str], use_post: bool, tag: str) -> dict | None:
        bases = [dict(params)]
        if sid:
            bases.append({**params, "_sid": sid})
        for bp in bases:
            p = dict(bp)
            if synotoken:
                p["SynoToken"] = synotoken
            try:
                d = api_entry(base, p, sid, insecure, use_post=use_post)
            except Exception as e:  # noqa: BLE001
                errors.append(f"{tag} {'POST' if use_post else 'GET'} exc: {e}")
                continue
            if d.get("success"):
                return d
            code = (d.get("error") or {}).get("code")
            errors.append(f"{tag} {'POST' if use_post else 'GET'} code {code}: {json.dumps(d)[:320]}")
        return None

    def try_json_params(method: str, params_obj: dict, tag: str) -> dict | None:
        try:
            d = api_entry_json_method(
                base,
                sp_api,
                1,
                method,
                params_obj,
                sid,
                insecure,
                synotoken=synotoken,
            )
        except Exception as e:  # noqa: BLE001
            errors.append(f"{tag} exc: {e}")
            return None
        if d.get("success"):
            return d
        code = (d.get("error") or {}).get("code")
        errors.append(f"{tag} code {code}: {json.dumps(d)[:320]}")
        return None

    def privilege_list_from_data(data: dict) -> tuple[str, list] | None:
        found = _nfs_privilege_find_list(data)
        if found:
            return found
        for nest in ("share_privilege", "privileges", "nfs", "share", "folder", "config", "settings"):
            inner = data.get(nest)
            if isinstance(inner, dict):
                found = _nfs_privilege_find_list(inner)
                if found:
                    return found
        return None

    def row_host(row: dict) -> str:
        return str(
            row.get("hostname")
            or row.get("host")
            or row.get("client")
            or row.get("ip")
            or row.get("allowed_host")
            or ""
        )

    share_rec = share_list_find_share(base, sid, share, insecure, synotoken)
    if not share_rec:
        print(
            "install.sh (DSM API): could not resolve shared folder via SYNO.Core.Share list; "
            "trying SharePrivilege with name only.",
            file=sys.stderr,
        )

    id_pairs: list[tuple[str, str]] = []
    if share_rec:
        for src_key, ik_group in (
            ("uuid", ("uuid", "share_folder_id", "folder_uuid", "share_uuid")),
            ("folder_uuid", ("folder_uuid", "uuid", "share_folder_id")),
            ("share_uuid", ("share_uuid", "uuid", "share_folder_id")),
        ):
            u = share_rec.get(src_key)
            if not u:
                continue
            uid = str(u)
            for ik in ik_group:
                id_pairs.append((ik, uid))

    load_share_keys: list[tuple[str, str]] = [
        ("name", json.dumps(share)),
        ("name", share),
        ("share_name", json.dumps(share)),
    ]
    if share_rec and share_rec.get("uuid"):
        u = str(share_rec["uuid"])
        load_share_keys.extend([("uuid", u), ("share_folder_id", u)])

    def nfs_new_row_variants(host: str) -> list[dict]:
        """Generate variations of NFS rules. DSM 7.2 prefers 'client', older prefers 'hostname'."""
        base_rows = []
        for h_key in ("client", "hostname"):
            for sq in ("map_all_users_to_admin", "no_mapping", "map_root_to_admin", 3):
                for priv in ("rw", "RW"):
                    # DSM 7.2 format (strict keys)
                    base_rows.append({h_key: host, "privilege": priv, "squash": sq, "security": "sys", "async": True, "cross_mnt": False, "insecure_ports": True})
                    # DSM 7.0 / 6.x format
                    base_rows.append({h_key: host, "privilege": priv, "squash": sq, "security": "sys", "async": True})
                    base_rows.append({h_key: host, "privilege": priv, "squash": sq, "security": "sys"})
        return base_rows

    def attempt_save(
        loaded: dict | None,
        list_key: str,
        merged: list,
        sk_hint: str | None,
        sv_hint: str | None,
    ) -> bool:
        if loaded is not None:
            try:
                doc = json.loads(json.dumps(loaded))
                doc[list_key] = merged
                if "name" not in doc:
                    doc["name"] = share
                if try_json_params("save", doc, f"save-json-fulldoc-{list_key}"):
                    return True
            except (TypeError, ValueError):
                pass

        list_blob = json.dumps(merged, separators=(",", ":"))
        
        h_pairs = []
        if sk_hint and sv_hint:
            h_pairs.append((sk_hint, sv_hint))
        h_pairs.extend([("name", share), ("name", json.dumps(share))])
        h_pairs.extend(id_pairs)
        
        seen_pairs = set()
        uniq_pairs = []
        for pair in h_pairs:
            if pair not in seen_pairs:
                seen_pairs.add(pair)
                uniq_pairs.append(pair)

        lk_order = list(dict.fromkeys([list_key, "nfs_rules", "nfs_share_list", "rules", "share_privilege"]))

        for lk in lk_order:
            for h_key, h_val in uniq_pairs:
                payload = {h_key: h_val, lk: merged}
                if h_key != "name":
                    payload["name"] = share
                if try_json_params("save", payload, f"save-json-{lk}-{h_key}"):
                    return True

        for lk in lk_order:
            for h_key, h_val in uniq_pairs:
                for use_post in (True, False):
                    save_p = {
                        "api": sp_api,
                        "version": ver,
                        "method": "save",
                        h_key: h_val,
                        lk: list_blob,
                    }
                    if h_key != "name":
                        save_p["name"] = share
                    if try_form(save_p, use_post, f"save-form-{lk}-{h_key}"):
                        return True

        return False

    loaded: dict | None = None
    load_sk_sv: tuple[str, str] | None = None

    for sk, sv in load_share_keys:
        load_p = {"api": sp_api, "version": ver, "method": "load", sk: sv}
        for use_post in (True, False):
            d = try_form(load_p, use_post, f"load-form-{sk}")
            if d and isinstance(d.get("data"), dict):
                loaded = d["data"]
                load_sk_sv = (sk, sv)
                break
        if loaded is not None:
            break

    if loaded is None:
        for sk, sv in load_share_keys:
            for val in (sv, share) if sk == "name" else (sv,):
                d = try_json_params("load", {sk: val}, f"load-json-{sk}")
                if d and isinstance(d.get("data"), dict):
                    loaded = d["data"]
                    load_sk_sv = (sk, sv)
                    break
            if loaded is not None:
                break

    if loaded is not None:
        found = privilege_list_from_data(loaded)
        if not found:
            errors.append(
                "load succeeded but privilege list shape unknown (data keys: "
                + ", ".join(list(loaded.keys())[:12])
                + ")."
            )
            for lk in ("nfs_share_list", "nfs_rules"):
                for variant in nfs_new_row_variants(client_host):
                    if attempt_save(loaded, lk, [variant], load_sk_sv[0], load_sk_sv[1]):
                        return
            raise SystemExit(
                "Could not set NFS SharePrivilege via API (load OK, cannot parse or save rules). "
                "DSM error 2301 usually means the save payload or NFS rule fields do not match this DSM version. "
                "Add NFS permission manually: Shared Folder → Edit → NFS Permissions → client IP.\nLast errors:\n"
                + "\n".join(errors[-20:])
            )
        list_key, existing = found
        merged = [x for x in existing if isinstance(x, dict)]
        for row in merged:
            if row_host(row) == client_host:
                print(
                    "install.sh (DSM API): NFS rule for this client already present; skipping add.",
                    file=sys.stderr,
                )
                return
        cand_rows: list[dict] = []
        if merged:
            tmpl = merged[0]
            # Copy tmpl perfectly but substitute the host key and try valid squashes
            for sq in ("map_all_users_to_admin", "no_mapping", "map_root_to_admin", 3):
                for priv in ("rw", "RW"):
                    v = dict(tmpl)
                    if "client" in v: v["client"] = client_host
                    elif "hostname" in v: v["hostname"] = client_host
                    elif "host" in v: v["host"] = client_host
                    else: v["client"] = client_host
                    v["privilege"] = priv
                    v["squash"] = sq
                    cand_rows.append(v)
        cand_rows.extend(nfs_new_row_variants(client_host))
        seen_sig: set[str] = set()
        for variant in cand_rows:
            sig = json.dumps(variant, sort_keys=True, separators=(",", ":"))
            if sig in seen_sig:
                continue
            seen_sig.add(sig)
            if attempt_save(loaded, list_key, merged + [variant], load_sk_sv[0], load_sk_sv[1]):
                return
    else:
        for variant in nfs_new_row_variants(client_host):
            if attempt_save(None, "nfs_share_list", [variant], None, None):
                return

    raise SystemExit(
        "Could not set NFS SharePrivilege via API. "
        "This API only supports load/save (not set). Error 2301 = invalid save payload on some DSM builds. "
        "If load fails, check share name, uuid, and DSM permissions. "
        "Add NFS permission manually: Shared Folder → Edit → NFS Permissions → client IP.\nLast errors:\n"
        + "\n".join(errors[-24:])
    )


def main() -> None:
    ap = argparse.ArgumentParser(description="Synology share + NFS rule (embedded in install.sh)")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--account", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--session", default="")
    ap.add_argument("--share-name", required=True)
    ap.add_argument("--vol-path", default="")
    ap.add_argument("--privilege-only", action="store_true")
    ap.add_argument("--client-host", required=True)
    ap.add_argument("--description", default="Proxmox NFS (install.sh)")
    ap.add_argument("--insecure-tls", action="store_true")
    args = ap.parse_args()

    if not args.privilege_only and not args.vol_path.strip():
        ap.error("--vol-path is required unless --privilege-only")

    base = args.base_url.rstrip("/")
    sid, synotoken = login(base, args.account, args.password, args.session, args.insecure_tls)
    if not args.privilege_only:
        share_create(
            base,
            sid,
            args.share_name,
            args.vol_path,
            args.description,
            args.insecure_tls,
            synotoken,
        )
    if nfs_service_enable_best_effort(base, sid, args.insecure_tls, synotoken):
        print("install.sh (DSM API): NFS service enable API call succeeded.", file=sys.stderr)
    else:
        print(
            "install.sh (DSM API): could not enable NFS via API; "
            "ensure File Services → NFS is enabled in DSM if exports are missing.",
            file=sys.stderr,
        )
    nfs_share_privilege_set(
        base,
        sid,
        args.share_name,
        args.client_host,
        args.insecure_tls,
        synotoken,
    )
    if args.privilege_only:
        print(json.dumps({"ok": True, "export_guess": ""}))
    else:
        print(
            json.dumps(
                {
                    "ok": True,
                    "export_guess": f"{args.vol_path.rstrip('/')}/{args.share_name}",
                }
            )
        )


if __name__ == "__main__":
    main()
INSTALL_SH_SYNOLOGY_NFS_PY_EOF
}

# Default nfs content: ISOs, CT templates, CT root dirs.
readonly DEFAULT_NFS_CONTENT="iso,vztmpl,rootdir"

configure_nfs_synology_storage() {
  local storage_id nfs_server nfs_export syno_folder_name syno_vol_prefix nfs_content nfs_options nfs_path
  local nfs_client_ip default_cip syno_api_user syno_api_pass syno_api_base_url syno_api_port
  local syno_api_https syno_api_check_ssl syno_api_session syno_py_args

  info "NFS storage (Proxmox type 'nfs'; Synology exports a Shared Folder over NFS)."
  info "The Synology Perl plugin is not required for this path."
  echo

  read_tty -p "Storage ID (e.g. synology-nfs): " REPLY
  storage_id=$(trim "${REPLY:-}")
  [[ -n "$storage_id" ]] || die "storage ID is required"
  [[ "$storage_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid storage ID format"
  if pvesm status "$storage_id" &>/dev/null; then
    die "storage '$storage_id' already exists"
  fi

  read_tty -p "Synology hostname or IP for NFS (no https://): " REPLY
  nfs_server=$(trim "${REPLY:-}")
  [[ -n "$nfs_server" ]] || die "server address is required"

  default_cip=$(default_ipv4_for_nfs_client "$nfs_server")
  read_tty -p "This Proxmox host IP for Synology NFS client rules [${default_cip}]: " REPLY
  nfs_client_ip=$(trim "${REPLY:-}")
  [[ -z "$nfs_client_ip" ]] && nfs_client_ip="$default_cip"
  [[ -n "$nfs_client_ip" ]] || die "client IP is required"

  echo
  if prompt_yesno "Create a new shared folder on the Synology for this NFS export?" y; then
    read_tty -p "New shared folder name (DSM name, e.g. proxmox-data): " REPLY
    syno_folder_name=$(trim "${REPLY:-}")
    [[ -n "$syno_folder_name" ]] || die "folder name is required"
    [[ "$syno_folder_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid folder name"
    read_tty -p "Volume path on the NAS [/volume1]: " REPLY
    syno_vol_prefix=$(trim "${REPLY:-}")
    [[ -z "$syno_vol_prefix" ]] && syno_vol_prefix="/volume1"
    syno_vol_prefix="${syno_vol_prefix%/}"
    nfs_export="${syno_vol_prefix}/${syno_folder_name}"

    if prompt_yesno "Create the folder and NFS permission via DSM Web API (uses username/password)?" y; then
      command -v python3 >/dev/null 2>&1 || die "python3 is required for DSM API provisioning"
      nfs_prompt_dsm_api_login
      nfs_build_dsm_base_url "$nfs_server"
      syno_py_args=(
        --base-url "${syno_api_base_url}"
        --account "${syno_api_user}"
        --password "${syno_api_pass}"
        --share-name "${syno_folder_name}"
        --vol-path "${syno_vol_prefix}"
        --client-host "${nfs_client_ip}"
      )
      [[ -n "${syno_api_session}" ]] && syno_py_args+=(--session "${syno_api_session}")
      [[ "${syno_api_check_ssl}" != y ]] && syno_py_args+=(--insecure-tls)
      echo
      info "Calling Synology DSM API (create share + NFS rule for ${nfs_client_ip})..."
      if ! run_synology_dsm_nfs_provision "${syno_py_args[@]}"; then
        die "DSM API provisioning failed. Fix credentials or create the share manually in DSM, then re-run."
      fi
      info "DSM API provisioning finished."
    else
      print_synology_nfs_dsm_steps "$syno_folder_name" "$nfs_export" "$nfs_server"
      echo
      read_tty -p "Press Enter when the folder and NFS export are ready..." _
    fi
  else
    read_tty -p "NFS export path (e.g. from pvesm scan nfs): " REPLY
    nfs_export=$(trim "${REPLY:-}")
    [[ -n "$nfs_export" ]] || die "export path is required"

    if prompt_yesno "Add an NFS permission rule for ${nfs_client_ip} via DSM Web API (existing share)?" n; then
      command -v python3 >/dev/null 2>&1 || die "python3 is required for DSM API provisioning"
      read_tty -p "DSM shared folder name (Control Panel name, not full path): " REPLY
      syno_folder_name=$(trim "${REPLY:-}")
      [[ -n "$syno_folder_name" ]] || die "shared folder name is required"
      nfs_prompt_dsm_api_login
      nfs_build_dsm_base_url "$nfs_server"
      syno_py_args=(
        --base-url "${syno_api_base_url}"
        --account "${syno_api_user}"
        --password "${syno_api_pass}"
        --share-name "${syno_folder_name}"
        --client-host "${nfs_client_ip}"
        --privilege-only
      )
      [[ -n "${syno_api_session}" ]] && syno_py_args+=(--session "${syno_api_session}")
      [[ "${syno_api_check_ssl}" != y ]] && syno_py_args+=(--insecure-tls)
      echo
      info "Calling DSM API to add NFS permission for ${nfs_client_ip}..."
      if ! run_synology_dsm_nfs_provision "${syno_py_args[@]}"; then
        die "DSM API failed. Add NFS permission manually in DSM, then re-run."
      fi
    fi
  fi

  read_tty -p "Proxmox content types [${DEFAULT_NFS_CONTENT}]: " REPLY
  nfs_content=$(trim "${REPLY:-}")
  [[ -z "$nfs_content" ]] && nfs_content="${DEFAULT_NFS_CONTENT}"

  if prompt_yesno "Also store backups (vzdump) on this NFS?" n; then
    nfs_content=$(append_csv_unique "$nfs_content" "backup")
  fi

  nfs_path="/mnt/pve/${storage_id}"
  nfs_options="vers=3"
  echo
  info "Default NFS mount options: vers=3 (recommended for Synology)."
  if prompt_yesno "Use custom NFS mount options instead (e.g. vers=4.1,soft)?" n; then
    read_tty -p "NFS options (empty = Proxmox default): " REPLY
    nfs_options=$(trim "${REPLY:-}")
  fi

  echo
  if prompt_yesno "Run pvesm scan nfs on ${nfs_server} now?" y; then
    pvesm scan nfs "$nfs_server" || true
    echo
  fi

  local cmd=(pvesm add nfs "$storage_id")
  cmd+=(--server "$nfs_server")
  cmd+=(--export "$nfs_export")
  cmd+=(--path "$nfs_path")
  cmd+=(--content "$nfs_content")
  [[ -n "$nfs_options" ]] && cmd+=(--options "$nfs_options")

  echo
  info "Command to run:"
  local i=0
  while ((i < ${#cmd[@]})); do
    printf ' %q' "${cmd[i]}"
    i=$((i + 1))
  done
  echo

  if [[ -n "${DRY_RUN:-}" ]]; then
    info "DRY_RUN is set - not executing pvesm."
    return 0
  fi

  if ! prompt_yesno "Add this NFS storage now?" y; then
    info "Aborted - no storage was added."
    return 0
  fi

  set +e
  "${cmd[@]}"
  local pvesm_rc=$?
  set -e
  [[ $pvesm_rc -eq 0 ]] || die "pvesm add nfs failed (exit $pvesm_rc). Check: export path matches 'pvesm scan nfs ${nfs_server}', DSM NFS rule for ${nfs_client_ip}, firewall, and storage ID spelling."

  if [[ ! -r /etc/pve/storage.cfg ]] || ! grep -Fx "nfs: $storage_id" /etc/pve/storage.cfg >/dev/null 2>&1; then
    die "pvesm reported success, but storage.cfg does not contain 'nfs: $storage_id'"
  fi

  if ! pvesm status "$storage_id" >/dev/null 2>&1; then
    die "Storage '${storage_id}' was added but is not online (mount failed). Try: pvesm remove ${storage_id}; confirm 'pvesm scan nfs ${nfs_server}' lists '${nfs_export}'; add DSM NFS permission for ${nfs_client_ip}; try custom options (e.g. vers=4.1). Check storage ID spelling."
  fi

  info "Done. Check: pvesm status $storage_id"
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
    echo "2) Configure Synology storage (iSCSI plugin or NFS share)"
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

  echo
  info "Storage backend: 1) iSCSI (Synology plugin)  2) NFS (Synology shared folder)"
  read_tty -p "Select [1/2] (default 1): " REPLY
  local backend
  backend=$(trim "${REPLY:-}")
  [[ -z "$backend" ]] && backend=1
  case "$backend" in
    2)
      configure_nfs_synology_storage
      return 0
      ;;
    1)
      ;;
    *)
      die "invalid choice — enter 1 or 2"
      ;;
  esac

  [[ -f "$SYNOLOGY_PLUGIN_PM" ]] || die "plugin not installed at $SYNOLOGY_PLUGIN_PM"

  info "Proxmox Synology iSCSI storage - interactive configuration"
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