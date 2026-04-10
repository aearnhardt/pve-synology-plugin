#!/usr/bin/env python3
"""
Synology DSM Web API helper: create a shared folder and NFS client rule for Proxmox.
Uses only the Python standard library (for Proxmox nodes without extra packages).

Typical flow:
  1) SYNO.API.Auth login -> sid cookie
  2) SYNO.Core.Share create (shared folder)
  3) SYNO.Core.FileServ.NFS set/save (enable NFS service) — best-effort across DSM builds
  4) SYNO.Core.FileServ.NFS.SharePrivilege load/save (JSON POST) — best-effort parameter variants
"""
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
    # 3301 = same shared folder name exists (DSM); 3312/3319 = name conflict; 1600 on some builds.
    if code in (1600, 3301, 3312, 3319):
        print(
            "synology-dsm-nfs-provision: shared folder already exists (create code "
            + str(code)
            + "); continuing to NFS permission step.",
            file=sys.stderr,
        )
        return
    raise SystemExit(f"SYNO.Core.Share create failed (code {code}): {json.dumps(d)}")


def nfs_service_enable_best_effort(
    base: str, sid: str, insecure: bool, synotoken: str = ""
) -> bool:
    """Try common DSM variants; return True if any call reports success."""
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
            "synology-dsm-nfs-provision: could not resolve shared folder via SYNO.Core.Share list; "
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
        """DSM builds differ on squash encoding (int vs string) and optional async flag; 2301 = bad rule shape."""
        return [
            {"hostname": host, "privilege": "RW", "squash": 3, "security": "sys", "async": True},
            {"hostname": host, "privilege": "rw", "squash": 3, "security": "sys", "async": True},
            {"hostname": host, "privilege": "RW", "squash": 3, "security": "sys"},
            {"hostname": host, "privilege": "RW", "squash": "all_squash_to_admin", "security": "sys", "async": True},
            {"hostname": host, "privilege": "RW", "squash": "map_all_users_to_admin", "security": "sys", "async": True},
            {"host": host, "privilege": "RW", "squash": 3, "security": "sys", "async": True},
        ]

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
                if try_json_params("save", doc, f"save-json-fulldoc-{list_key}"):
                    return True
            except (TypeError, ValueError):
                pass
        list_blob = json.dumps(merged, separators=(",", ":"))
        share_opts: list[tuple[str, str]] = []
        if sk_hint and sv_hint:
            share_opts.append((sk_hint, sv_hint))
        share_opts.extend(
            [
                ("name", json.dumps(share)),
                ("name", share),
                ("share_name", json.dumps(share)),
            ]
        )
        share_opts.extend(id_pairs)
        seen: set[tuple[str, str]] = set()
        uniq_sk: list[tuple[str, str]] = []
        for pair in share_opts:
            if pair not in seen:
                seen.add(pair)
                uniq_sk.append(pair)
        lk_order = list(
            dict.fromkeys(
                [list_key]
                + [
                    "nfs_share_list",
                    "nfs_rules",
                    "rules",
                    "share_privilege",
                    "privileges",
                    "hosts",
                    "clients",
                ]
            )
        )
        for sk, sv in uniq_sk:
            for lk in lk_order:
                save_p = {
                    "api": sp_api,
                    "version": ver,
                    "method": "save",
                    sk: sv,
                    lk: list_blob,
                }
                for use_post in (True, False):
                    if try_form(save_p, use_post, f"save-form-{lk}"):
                        return True
        for sk, sv in uniq_sk:
            for lk in lk_order:
                if try_json_params("save", {sk: sv, lk: merged}, f"save-json-{lk}-{sk}"):
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
                    "synology-dsm-nfs-provision: NFS rule for this client already present; skipping add.",
                    file=sys.stderr,
                )
                return
        cand_rows: list[dict] = []
        if merged:
            tmpl = merged[0]
            for v in nfs_new_row_variants(client_host):
                cand_rows.append({**tmpl, **v})
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
    ap = argparse.ArgumentParser(description="Create Synology share + NFS rule for Proxmox")
    ap.add_argument("--base-url", required=True, help="e.g. https://192.168.1.10:5001")
    ap.add_argument("--account", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--session", default="", help="Optional DSM session name for SYNO.API.Auth")
    ap.add_argument("--share-name", required=True)
    ap.add_argument(
        "--vol-path",
        default="",
        help="e.g. /volume1 (required unless --privilege-only)",
    )
    ap.add_argument(
        "--privilege-only",
        action="store_true",
        help="Skip shared folder create; only enable NFS (best effort) and add NFS client rule",
    )
    ap.add_argument("--client-host", required=True, help="Proxmox NFS client IP or hostname for DSM rule")
    ap.add_argument("--description", default="Proxmox NFS (pve-synology-plugin)")
    ap.add_argument("--insecure-tls", action="store_true", help="Skip TLS verification (self-signed DSM cert)")
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
        print("synology-dsm-nfs-provision: NFS service enable API call succeeded.", file=sys.stderr)
    else:
        print(
            "synology-dsm-nfs-provision: could not enable NFS via API; "
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
