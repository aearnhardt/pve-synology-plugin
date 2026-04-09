#!/usr/bin/env python3
"""
GUI helper for Synology DSM 7.x SAN Manager: list LUNs per iSCSI target, inspect/edit
size, create new LUNs mapped to a target (with dev_attribs can_snapshot=1 for thin-capable
types), list/take/delete/restore LUN snapshots (revert_snapshot), and delete the selected
LUN (removing snapshots first).

Uses the same Web API patterns as SynologyStoragePlugin.pm (SYNO.API.Auth, entry.cgi,
SYNO.Core.ISCSI.LUN list/get/set/create + map_target, list_snapshot/take_snapshot/
delete_snapshot/revert_snapshot + delete, SYNO.Core.ISCSI.Target list).

Requires PyQt6 (Apple's system Tcl/Tk often does not paint Entry/Label at all on macOS).
If missing, the script offers to run ``python -m pip install PyQt6`` (TTY), or set
``SYNOLOGY_LUN_GUI_AUTO_INSTALL_PYQT=1`` for non-interactive installs.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import ssl
from typing import Optional

from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

LUN_TYPES = (
    "THIN",
    "FILE",
    "BLOCK",
    "BLUN",
    "BLUN_THICK",
    "ADV",
    "SINK",
    "CINDER",
    "CINDER_BLUN",
    "CINDER_BLUN_THICK",
    "BLUN_SINK",
    "BLUN_THICK_SINK",
)

# Thin LUN types where DSM accepts dev_attribs can_snapshot=1 at create (see Synology CSI /
# democratic-csi). FILE, BLOCK, BLUN_THICK, etc. are not listed — snapshots are unsupported
# or not requested for those types.
LUN_TYPES_REQUEST_CAN_SNAPSHOT_AT_CREATE = frozenset(
    ("THIN", "ADV", "BLUN", "BLUN_SINK", "CINDER", "CINDER_BLUN")
)

LUN_TYPES_API = (
    '["BLOCK", "FILE", "THIN", "ADV", "SINK", "CINDER", "CINDER_BLUN", '
    '"CINDER_BLUN_THICK", "BLUN", "BLUN_THICK", "BLUN_SINK", "BLUN_THICK_SINK"]'
)

LUN_ADDITIONAL = (
    '["allocated_size", "status", "flashcache_status", "is_action_locked", '
    '"dev_attribs"]'
)

TARGET_ADDITIONAL = '["mapped_lun", "connected_sessions"]'


def create_lun_dev_attribs_json(lun_type: str) -> str:
    """JSON array for SYNO.Core.ISCSI.LUN create `dev_attribs` (enable snapshots when supported)."""
    t = (lun_type or "").strip()
    if t in LUN_TYPES_REQUEST_CAN_SNAPSHOT_AT_CREATE:
        return json.dumps(
            [{"dev_attrib": "can_snapshot", "enable": 1}],
            separators=(",", ":"),
        )
    return "[]"


def dsm_string_param(s: str) -> str:
    s = s or ""
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s + '"'


def dsm_api_error_explain(code: object) -> str:
    """
    Best-effort explanations for SYNO.Core.ISCSI.* entry.cgi error codes.
    Official DSM docs rarely list these; some codes appear in Synology CSI sources.
    """
    try:
        c = int(code)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return ""
    hints: dict[int, str] = {
        # entry.cgi generic WEBAPI_* codes (same numbering as DSM docs / SynologyStoragePlugin.pm).
        102: "No such API.",
        103: (
            "No such method for this API version, or not implemented on this DSM build."
        ),
        104: (
            "Unsupported API version: the version= field is higher than this NAS "
            "advertises for the API (see SYNO.API.Info), or the request does not "
            "match the method schema for that version."
        ),
        18990002: "Out of free space on the volume.",
        18990500: (
            "Invalid or unsupported LUN type or operation for this NAS/volume. "
            "For snapshots: in LUN settings, find dev_attribs → can_snapshot; if "
            "enable is 0, DSM will not allow take_snapshot (you may still see "
            "error 18990500 even for a “THIN” LUN if the backing volume/pool does "
            "not support SCSI LUN snapshots). Prefer THIN on a pool where SAN "
            "Manager allows it; FILE/Btrfs-backed LUNs often have can_snapshot=0."
        ),
        18990503: "Invalid parameter (for example, LUN name rejected by DSM).",
        18990517: "API parameter mismatch (firmware may require different request shape).",
        18990531: "LUN not found.",
        18990532: "Snapshot not found.",
        18990538: "A LUN with this name already exists.",
        18990541: "Maximum LUN count reached for this NAS.",
        18990543: "Maximum snapshot count reached.",
        # Observed when creating BLOCK on pools where DSM only allows thin/file-based LUNs:
        18991205: (
            "DSM does not allow this LUN type on the selected volume (common on "
            "Btrfs pools). Try THIN first; FILE or BLUN may also work. BLOCK is often "
            "for thick/block layouts that the pool does not support."
        ),
    }
    return hints.get(c, "")


def _coerce_mapped_lun_array(raw: object) -> list:
    """Normalize DSM variants (nested additional, JSON string, single dict) to a list."""
    if raw is None:
        return []
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return []
        try:
            return _coerce_mapped_lun_array(json.loads(s))
        except json.JSONDecodeError:
            return []
    if isinstance(raw, dict):
        if "lun_uuid" in raw or "uuid" in raw:
            return [raw]
        inner = (
            raw.get("mapped_luns")
            or raw.get("mapped_lun")
            or raw.get("luns")
        )
        if inner is not None:
            return _coerce_mapped_lun_array(inner)
        return []
    if isinstance(raw, list):
        return raw
    return []


def _raw_mapped_luns_from_target(target: dict) -> list:
    """Collect mapped-LUN payload from top-level and optional additional{}."""
    for key in ("mapped_luns", "mapped_lun"):
        v = target.get(key)
        if v is not None:
            return _coerce_mapped_lun_array(v)
    add = target.get("additional")
    if isinstance(add, dict):
        for key in ("mapped_luns", "mapped_lun", "mapped_luns_list"):
            v = add.get(key)
            if v is not None:
                return _coerce_mapped_lun_array(v)
    return []


def mapped_lun_entries(target: dict) -> list[tuple[int, str]]:
    """
    Extract (mapping_index, lun_uuid) from a Target dict.
    DSM / CSI use mapped_luns: [{ "lun_uuid": "...", "mapping_index": n }, ...].
    """
    raw = _raw_mapped_luns_from_target(target)
    out: list[tuple[int, str]] = []
    for i, item in enumerate(raw):
        if isinstance(item, str) and item:
            out.append((i, item))
            continue
        if not isinstance(item, dict):
            continue
        u = item.get("lun_uuid") or item.get("uuid") or ""
        if not u:
            continue
        mi = item.get("mapping_index")
        try:
            idx = int(mi) if mi is not None else i
        except (TypeError, ValueError):
            idx = i
        out.append((idx, str(u)))
    out.sort(key=lambda x: x[0])
    return out


def lun_settings_text(lun: dict) -> str:
    lines: list[str] = []
    order = [
        "name",
        "uuid",
        "type",
        "size",
        "allocated_size",
        "location",
        "description",
        "status",
        "flashcache_status",
        "is_action_locked",
    ]
    seen: set[str] = set()
    for k in order:
        if k not in lun:
            continue
        seen.add(k)
        v = lun[k]
        if k == "size" and isinstance(v, (int, float)):
            gib = v / (1024**3)
            lines.append(f"{k}: {v} bytes (~{gib:.3f} GiB)")
        elif k == "allocated_size" and isinstance(v, (int, float)):
            gib = v / (1024**3)
            lines.append(f"{k}: {v} bytes (~{gib:.3f} GiB)")
        else:
            lines.append(f"{k}: {v}")
    for k in sorted(lun.keys()):
        if k in seen:
            continue
        lines.append(f"{k}: {lun[k]}")
    return "\n".join(lines) if lines else "(no data)"


def lun_size_bytes(lun: dict) -> Optional[int]:
    raw = lun.get("size")
    if raw is None:
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def lun_dev_attrib_rows(lun: dict) -> list[dict]:
    """Normalize DSM `dev_attribs` (list, JSON string, or wrapper dict) to dict rows."""
    raw = lun.get("dev_attribs")
    if raw is None:
        return []
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return []
        try:
            raw = json.loads(s)
        except json.JSONDecodeError:
            return []
    if isinstance(raw, dict):
        if "dev_attrib" in raw or "dev_attribs" in raw:
            inner = raw.get("dev_attribs")
            if inner is not None:
                return lun_dev_attrib_rows({"dev_attribs": inner})
            return [raw] if raw.get("dev_attrib") is not None else []
    if isinstance(raw, list):
        return [x for x in raw if isinstance(x, dict)]
    return []


def lun_snapshot_allowed_by_dsm(lun: dict) -> Optional[bool]:
    """
    If DSM includes `can_snapshot` in dev_attribs, return whether snapshots are allowed.
    None if the flag is absent — the API may still be tried.
    """
    for row in lun_dev_attrib_rows(lun):
        key = row.get("dev_attrib") or row.get("name") or ""
        if str(key).strip().lower() != "can_snapshot":
            continue
        en = row.get("enable")
        if en is None:
            return None
        if isinstance(en, bool):
            return en
        if isinstance(en, str):
            low = en.strip().lower()
            if low in ("true", "1", "yes"):
                return True
            if low in ("false", "0", "no"):
                return False
        try:
            return int(en) != 0
        except (TypeError, ValueError):
            return bool(en)
    return None


def snapshot_list_item_label(snap: dict) -> tuple[str, str]:
    """
    Build combo-box label and snapshot uuid from a list_snapshot entry.
    """
    if not isinstance(snap, dict):
        return ("(invalid entry)", "")
    su = str(snap.get("uuid") or "").strip()
    name = str(snap.get("name") or "").strip()
    if not name:
        name = su[:10] + "…" if len(su) > 10 else su or "(unnamed)"
    extra = snap.get("description") or snap.get("time") or snap.get("timestamp")
    if isinstance(extra, str) and extra.strip():
        return (f"{name}  —  {extra.strip()[:80]}", su)
    return (name, su)


def normalize_lun_map_entries(entries: object) -> list[tuple[int, str]]:
    """Turn PyQt/signal payloads into [(mapping_index, uuid), ...]."""
    out: list[tuple[int, str]] = []
    if not isinstance(entries, list):
        return out
    for item in entries:
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            try:
                out.append((int(item[0]), str(item[1])))
            except (TypeError, ValueError):
                pass
    return out


class SynologyClient:
    def __init__(
        self,
        host: str,
        *,
        use_https: bool = True,
        port: Optional[int] = None,
        verify_ssl: bool = False,
        session_name: str = "",
    ) -> None:
        host = host.strip()
        for prefix in ("https://", "http://"):
            if host.lower().startswith(prefix):
                host = host[len(prefix) :]
                break
        if "/" in host:
            host = host.split("/")[0]
        if host.endswith(":5001") or host.endswith(":5000"):
            parts = host.rsplit(":", 1)
            host = parts[0]
        self.host = host
        self.use_https = use_https
        self.port = port if port is not None else (5001 if use_https else 5000)
        self.verify_ssl = verify_ssl
        self.session_name = session_name.strip()
        self.sid: Optional[str] = None

    def _base(self) -> str:
        scheme = "https" if self.use_https else "http"
        return f"{scheme}://{self.host}:{self.port}"

    def _ssl_context(self) -> Optional[ssl.SSLContext]:
        if not self.use_https:
            return None
        if self.verify_ssl:
            return None
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx

    def _get(
        self, path: str, query: list[tuple[str, str]], cookie_sid: Optional[str] = None
    ) -> dict:
        pairs = [(k, quote(v, safe="")) for k, v in query]
        url = self._base() + path + "?" + "&".join(f"{k}={v}" for k, v in pairs)
        req = Request(url, method="GET")
        if cookie_sid:
            req.add_header("Cookie", f"id={cookie_sid}")
        try:
            with urlopen(req, timeout=120, context=self._ssl_context()) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except HTTPError as e:
            raise RuntimeError(f"HTTP {e.code}: {e.reason}") from e
        except URLError as e:
            raise RuntimeError(f"Connection failed: {e.reason}") from e
        try:
            data = json.loads(body)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Invalid JSON from NAS: {body[:200]}…") from e
        if not isinstance(data, dict):
            raise RuntimeError("Unexpected API response shape")
        return data

    def login(self, account: str, passwd: str) -> None:
        q = [
            ("api", "SYNO.API.Auth"),
            ("version", "3"),
            ("method", "login"),
            ("account", account),
            ("passwd", passwd),
            ("format", "sid"),
        ]
        if self.session_name:
            q.append(("session", self.session_name))
        data = self._get("/webapi/auth.cgi", q)
        if not data.get("success"):
            code = (data.get("error") or {}).get("code", "?")
            raise RuntimeError(f"Login failed (error code {code})")
        sid = (data.get("data") or {}).get("sid")
        if not sid:
            raise RuntimeError("Login returned no session id")
        self.sid = sid

    def entry(self, params: list[tuple[str, str]], *, retry_auth: bool = True) -> dict:
        if not self.sid:
            raise RuntimeError("Not logged in")
        q = list(params)
        data = self._get("/webapi/entry.cgi", q, cookie_sid=self.sid)
        if data.get("success"):
            inner = data.get("data")
            return inner if isinstance(inner, dict) else {}
        code = (data.get("error") or {}).get("code")
        if retry_auth and code in (105, 106, 119):
            raise RuntimeError("SESSION_EXPIRED")
        hint = dsm_api_error_explain(code)
        msg = f"API error code {code}"
        if hint:
            msg = f"{msg}\n\n{hint}"
        raise RuntimeError(msg)

    def api_info_max_version(self, api_name: str) -> Optional[int]:
        """
        Read SYNO.API.Info maxVersion for an API (same query as SynologyStoragePlugin.pm).
        """
        if not self.sid:
            raise RuntimeError("Not logged in")
        data = self._get(
            "/webapi/query.cgi",
            [
                ("api", "SYNO.API.Info"),
                ("version", "1"),
                ("method", "query"),
                ("query", api_name),
            ],
            cookie_sid=self.sid,
        )
        if not isinstance(data, dict) or not data.get("success"):
            return None
        root = data.get("data")
        if not isinstance(root, dict):
            return None
        slot = root.get(api_name)
        if not isinstance(slot, dict):
            return None
        raw = slot.get("maxVersion")
        if raw is None:
            raw = slot.get("max_version")
        try:
            m = int(raw)
        except (TypeError, ValueError):
            return None
        if m < 1:
            return None
        return min(m, 15)

    def list_targets(self) -> list[dict]:
        # Some DSM 7.2 builds return 18990517 on Target list when "additional" JSON
        # does not match what the firmware expects; fall back to a minimal list call.
        full = [
            ("api", "SYNO.Core.ISCSI.Target"),
            ("method", "list"),
            ("version", "1"),
            ("additional", dsm_string_param(TARGET_ADDITIONAL)),
        ]
        minimal = [
            ("api", "SYNO.Core.ISCSI.Target"),
            ("method", "list"),
            ("version", "1"),
        ]
        try:
            data = self.entry(full)
        except RuntimeError as e:
            if "18990517" in str(e):
                data = self.entry(minimal)
            else:
                raise
        targets = data.get("targets")
        return targets if isinstance(targets, list) else []

    def get_target(self, target_id: int, *, minimal: bool = False) -> dict:
        q: list[tuple[str, str]] = [
            ("api", "SYNO.Core.ISCSI.Target"),
            ("method", "get"),
            ("version", "1"),
            ("target_id", dsm_string_param(str(int(target_id)))),
        ]
        if not minimal:
            q.append(("additional", dsm_string_param(TARGET_ADDITIONAL)))
        data = self.entry(q)
        tgt = data.get("target")
        return tgt if isinstance(tgt, dict) else {}

    def list_luns(self) -> list[dict]:
        # DSM 7.2+ often returns 18990517 if "additional" (or combined params) is not
        # exactly what the firmware expects; try lighter calls (same idea as list_targets).
        base = ("api", "SYNO.Core.ISCSI.LUN"), ("method", "list"), ("version", "1")
        attempts: list[list[tuple[str, str]]] = [
            [
                base[0],
                base[1],
                base[2],
                ("types", LUN_TYPES_API),
                ("additional", dsm_string_param(LUN_ADDITIONAL)),
            ],
            [base[0], base[1], base[2], ("types", LUN_TYPES_API)],
            [base[0], base[1], base[2]],
        ]
        last_err: Optional[RuntimeError] = None
        for q in attempts:
            try:
                data = self.entry(q)
            except RuntimeError as e:
                last_err = e
                if "18990517" not in str(e):
                    raise
                continue
            luns = data.get("luns")
            return luns if isinstance(luns, list) else []
        if last_err is not None:
            raise last_err
        return []

    def get_lun(self, uuid: str) -> dict:
        uq = dsm_string_param(str(uuid))
        attempts = [
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "get"),
                ("version", "1"),
                ("uuid", uq),
                ("additional", dsm_string_param(LUN_ADDITIONAL)),
            ],
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "get"),
                ("version", "1"),
                ("uuid", uq),
            ],
        ]
        last_err: Optional[RuntimeError] = None
        for q in attempts:
            try:
                data = self.entry(q)
            except RuntimeError as e:
                last_err = e
                if "18990517" not in str(e):
                    raise
                continue
            lun = data.get("lun")
            return lun if isinstance(lun, dict) else {}
        if last_err is not None:
            raise last_err
        return {}

    def set_lun_size(self, uuid: str, size_bytes: int) -> None:
        self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "set"),
                ("version", "1"),
                ("uuid", dsm_string_param(str(uuid))),
                ("new_size", str(int(size_bytes))),
            ]
        )

    def list_volume_paths(self) -> list[str]:
        data = self.entry(
            [
                ("api", "SYNO.Core.Storage.Volume"),
                ("method", "list"),
                ("version", "1"),
                ("offset", "0"),
                ("limit", "-1"),
                ("location", "all"),
            ]
        )
        vols = data.get("volumes")
        if not isinstance(vols, list):
            return []
        paths: set[str] = set()
        for v in vols:
            if not isinstance(v, dict):
                continue
            p = v.get("volume_path") or v.get("path") or ""
            if isinstance(p, str) and p.startswith("/volume"):
                paths.add(p)
        return sorted(paths)

    def create_lun_and_map(
        self,
        *,
        name: str,
        size_bytes: int,
        lun_type: str,
        location: str,
        description: str,
        target_id: int,
    ) -> str:
        create = self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "create"),
                ("version", "1"),
                ("name", dsm_string_param(name)),
                ("size", str(int(size_bytes))),
                ("type", lun_type),
                ("location", location),
                ("description", dsm_string_param(description)),
                ("dev_attribs", create_lun_dev_attribs_json(lun_type)),
            ]
        )
        uuid = create.get("uuid")
        if not uuid:
            raise RuntimeError("LUN create returned no uuid")
        self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "map_target"),
                ("version", "1"),
                ("uuid", dsm_string_param(str(uuid))),
                ("target_ids", json.dumps([int(target_id)])),
            ]
        )
        return str(uuid)

    def list_snapshots(self, lun_uuid: str) -> list[dict]:
        data = self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "list_snapshot"),
                ("version", "1"),
                ("src_lun_uuid", dsm_string_param(str(lun_uuid))),
            ]
        )
        snaps = data.get("snapshots")
        return snaps if isinstance(snaps, list) else []

    def take_snapshot(
        self,
        src_lun_uuid: str,
        snapshot_name: str,
        *,
        description: str = "",
    ) -> None:
        desc = description.strip() if description else ""
        if not desc:
            desc = f"Snapshot {snapshot_name} (synology_lun_gui)"
        self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "take_snapshot"),
                ("version", "1"),
                ("src_lun_uuid", dsm_string_param(str(src_lun_uuid))),
                ("snapshot_name", dsm_string_param(snapshot_name)),
                ("description", dsm_string_param(desc)),
                ("taken_by", dsm_string_param("synology_lun_gui")),
                ("is_locked", "false"),
                ("is_app_consistent", "false"),
            ]
        )

    def delete_snapshot(self, snapshot_uuid: str) -> None:
        self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "delete_snapshot"),
                ("version", "1"),
                ("snapshot_uuid", dsm_string_param(str(snapshot_uuid))),
            ]
        )

    def revert_snapshot(self, src_lun_uuid: str, snapshot_uuid: str) -> None:
        """
        Roll the LUN back to the given snapshot. DSM builds differ: some only
        advertise maxVersion=1 for SYNO.Core.ISCSI.LUN (so version=2..N always
        returns 104), parameter names may be src_lun_uuid or uuid, and the method
        may be revert_snapshot or restore_snapshot.
        """
        lu = str(src_lun_uuid).strip()
        su = str(snapshot_uuid).strip()
        lun_q = dsm_string_param(lu)
        snap_q = dsm_string_param(su)
        reported = self.api_info_max_version("SYNO.Core.ISCSI.LUN")
        if reported is not None:
            max_ver = max(1, min(reported, 10))
        else:
            max_ver = 5
        variants: list[tuple[str, list[tuple[str, str]]]] = [
            ("revert_snapshot", [("src_lun_uuid", lun_q), ("snapshot_uuid", snap_q)]),
            ("revert_snapshot", [("uuid", lun_q), ("snapshot_uuid", snap_q)]),
            ("restore_snapshot", [("src_lun_uuid", lun_q), ("snapshot_uuid", snap_q)]),
            ("restore_snapshot", [("uuid", lun_q), ("snapshot_uuid", snap_q)]),
            ("revert_snapshot", [("snapshot_uuid", snap_q)]),
        ]
        last_err: Optional[RuntimeError] = None
        for ver in range(1, max_ver + 1):
            for method, extra in variants:
                params: list[tuple[str, str]] = [
                    ("api", "SYNO.Core.ISCSI.LUN"),
                    ("method", method),
                    ("version", str(ver)),
                ] + extra
                try:
                    self.entry(params)
                    return
                except RuntimeError as e:
                    es = str(e)
                    if es == "SESSION_EXPIRED":
                        raise
                    last_err = e
                    if "error code 103" in es or "error code 104" in es:
                        continue
                    raise
        if last_err is not None:
            es = str(last_err)
            if "error code 103" in es or "error code 104" in es:
                raise RuntimeError(
                    es
                    + "\n\nIn-place snapshot restore was tried for "
                    f"SYNO.Core.ISCSI.LUN versions 1–{max_ver} with methods "
                    "revert_snapshot / restore_snapshot and common parameter "
                    "layouts. Many DSM 7 SAN Manager builds do not expose this "
                    "over the Web API; use DSM to restore the LUN, or clone the "
                    "snapshot to a new LUN (clone_snapshot)."
                ) from last_err
            raise last_err
        raise RuntimeError("revert_snapshot failed")

    def delete_lun(self, lun_uuid: str) -> None:
        self.entry(
            [
                ("api", "SYNO.Core.ISCSI.LUN"),
                ("method", "delete"),
                ("version", "1"),
                ("uuid", dsm_string_param(str(lun_uuid))),
            ]
        )


def _try_import_pyqt6() -> bool:
    try:
        from PyQt6.QtCore import QThread, pyqtSignal  # noqa: F401
        from PyQt6.QtWidgets import QApplication  # noqa: F401
    except ImportError:
        return False
    return True


def _pip_install_pyqt6() -> bool:
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pip", "install", "PyQt6"],
            check=False,
        )
        return r.returncode == 0
    except OSError:
        return False


def _require_qt() -> None:
    if _try_import_pyqt6():
        return

    hint = (
        "This GUI needs PyQt6 (macOS system Tk often cannot draw text fields).\n"
        "Install manually with:\n"
        f"  {sys.executable} -m pip install PyQt6\n"
    )
    offer = False
    if sys.stdin.isatty() and sys.stdout.isatty():
        try:
            ans = input(
                "PyQt6 is not installed. Install it now with pip? [y/N] "
            ).strip().lower()
        except EOFError:
            ans = ""
        offer = ans in ("y", "yes")
    else:
        flag = os.environ.get("SYNOLOGY_LUN_GUI_AUTO_INSTALL_PYQT", "").strip().lower()
        offer = flag in ("1", "y", "yes", "true")

    if offer:
        print("Installing PyQt6...", file=sys.stderr)
        if _pip_install_pyqt6() and _try_import_pyqt6():
            return
        print(
            "Could not install or import PyQt6. "
            "Use the same Python interpreter for pip and this script, then retry.",
            file=sys.stderr,
        )

    print(hint, file=sys.stderr)
    sys.exit(1)


def main() -> None:
    _require_qt()
    from PyQt6.QtCore import Qt, QThread, pyqtSignal
    from PyQt6.QtWidgets import (
        QApplication,
        QCheckBox,
        QComboBox,
        QFormLayout,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QListWidget,
        QListWidgetItem,
        QMessageBox,
        QPushButton,
        QScrollArea,
        QSpinBox,
        QStyleFactory,
        QTextEdit,
        QVBoxLayout,
        QWidget,
    )

    _HIGH_CONTRAST_QSS = """
        QWidget { background-color: #2b2b2b; color: #f2f2f2; }
        QLabel { color: #f2f2f2; font-size: 13px; }
        QLineEdit, QSpinBox, QComboBox, QListWidget, QTextEdit {
            background-color: #ffffff;
            color: #111111;
            border: 2px solid #6b6b6b;
            border-radius: 4px;
            padding: 5px;
            font-size: 13px;
            selection-background-color: #2563eb;
            selection-color: #ffffff;
        }
        QLineEdit:focus, QSpinBox:focus, QComboBox:focus, QListWidget:focus, QTextEdit:focus {
            border: 2px solid #3b82f6;
        }
        QComboBox::drop-down { border: none; width: 24px; }
        QPushButton {
            background-color: #3f3f46;
            color: #ffffff;
            border: 2px solid #71717a;
            border-radius: 4px;
            padding: 8px 14px;
            font-size: 13px;
        }
        QPushButton:hover { background-color: #52525b; }
        QPushButton:pressed { background-color: #27272a; }
        QPushButton:disabled { color: #a1a1aa; border-color: #52525b; }
        QCheckBox { color: #f2f2f2; font-size: 13px; spacing: 8px; }
        QCheckBox::indicator { width: 18px; height: 18px; }
        QListWidget::item:selected { background-color: #2563eb; color: #ffffff; }
        QSpinBox::up-button, QSpinBox::down-button { background-color: #e5e5e5; width: 18px; }
        QScrollArea { border: none; background-color: #2b2b2b; }
        QScrollBar:vertical {
            background-color: #3f3f46;
            width: 14px;
            margin: 0;
        }
        QScrollBar::handle:vertical {
            background-color: #71717a;
            min-height: 24px;
            border-radius: 3px;
        }
        QScrollBar::handle:vertical:hover { background-color: #a1a1aa; }
        QScrollBar:horizontal {
            background-color: #3f3f46;
            height: 14px;
            margin: 0;
        }
        QScrollBar::handle:horizontal {
            background-color: #71717a;
            min-width: 24px;
            border-radius: 3px;
        }
        QScrollBar::handle:horizontal:hover { background-color: #a1a1aa; }
    """

    class ConnectWorker(QThread):
        finished_ok = pyqtSignal(object)
        finished_err = pyqtSignal(str)

        def __init__(
            self,
            host: str,
            user: str,
            password: str,
            use_https: bool,
            port: Optional[int],
            verify_ssl: bool,
            session_name: str,
        ) -> None:
            super().__init__()
            self._host = host
            self._user = user
            self._password = password
            self._use_https = use_https
            self._port = port
            self._verify_ssl = verify_ssl
            self._session_name = session_name

        def run(self) -> None:
            try:
                client = SynologyClient(
                    self._host,
                    use_https=self._use_https,
                    port=self._port,
                    verify_ssl=self._verify_ssl,
                    session_name=self._session_name,
                )
                client.login(self._user, self._password)
                targets = client.list_targets()
                try:
                    paths = client.list_volume_paths()
                except RuntimeError as e:
                    if "18990517" in str(e):
                        paths = []
                    else:
                        raise
                luns = client.list_luns()
                self.finished_ok.emit((client, targets, paths, luns))
            except Exception as e:
                self.finished_err.emit(str(e))

    class CreateWorker(QThread):
        finished_ok = pyqtSignal(str)
        finished_err = pyqtSignal(str)

        def __init__(self, client: SynologyClient, **kw) -> None:
            super().__init__()
            self._client = client
            self._kw = kw

        def run(self) -> None:
            try:
                uuid = self._client.create_lun_and_map(**self._kw)
                self.finished_ok.emit(uuid)
            except Exception as e:
                self.finished_err.emit(str(e))

    class LunGetWorker(QThread):
        finished_ok = pyqtSignal(int, str, object)
        finished_err = pyqtSignal(int, str)

        def __init__(self, client: SynologyClient, seq: int, lun_uuid: str) -> None:
            super().__init__()
            self._client = client
            self._seq = seq
            self._lun_uuid = lun_uuid

        def run(self) -> None:
            try:
                lun = self._client.get_lun(self._lun_uuid)
                self.finished_ok.emit(self._seq, self._lun_uuid, lun)
            except Exception as e:
                self.finished_err.emit(self._seq, str(e))

    class LunResizeWorker(QThread):
        finished_ok = pyqtSignal(str)
        finished_err = pyqtSignal(str)

        def __init__(
            self, client: SynologyClient, lun_uuid: str, size_bytes: int
        ) -> None:
            super().__init__()
            self._client = client
            self._lun_uuid = lun_uuid
            self._size_bytes = size_bytes

        def run(self) -> None:
            try:
                self._client.set_lun_size(self._lun_uuid, self._size_bytes)
                self.finished_ok.emit(self._lun_uuid)
            except Exception as e:
                self.finished_err.emit(str(e))

    class ListSnapshotsWorker(QThread):
        finished_ok = pyqtSignal(int, str, object)
        finished_err = pyqtSignal(int, str, str)

        def __init__(self, client: SynologyClient, seq: int, lun_uuid: str) -> None:
            super().__init__()
            self._client = client
            self._seq = seq
            self._lun_uuid = lun_uuid

        def run(self) -> None:
            try:
                snaps = self._client.list_snapshots(self._lun_uuid)
                self.finished_ok.emit(self._seq, self._lun_uuid, snaps)
            except Exception as e:
                self.finished_err.emit(self._seq, self._lun_uuid, str(e))

    class TakeSnapshotWorker(QThread):
        finished_ok = pyqtSignal(str)
        finished_err = pyqtSignal(str)

        def __init__(
            self,
            client: SynologyClient,
            lun_uuid: str,
            snapshot_name: str,
            description: str,
        ) -> None:
            super().__init__()
            self._client = client
            self._lun_uuid = lun_uuid
            self._snapshot_name = snapshot_name
            self._description = description

        def run(self) -> None:
            try:
                self._client.take_snapshot(
                    self._lun_uuid,
                    self._snapshot_name,
                    description=self._description,
                )
                self.finished_ok.emit(self._lun_uuid)
            except Exception as e:
                self.finished_err.emit(str(e))

    class DeleteSnapshotWorker(QThread):
        finished_ok = pyqtSignal(str)
        finished_err = pyqtSignal(str)

        def __init__(
            self, client: SynologyClient, lun_uuid: str, snapshot_uuid: str
        ) -> None:
            super().__init__()
            self._client = client
            self._lun_uuid = lun_uuid
            self._snapshot_uuid = snapshot_uuid

        def run(self) -> None:
            try:
                self._client.delete_snapshot(self._snapshot_uuid)
                self.finished_ok.emit(self._lun_uuid)
            except Exception as e:
                self.finished_err.emit(str(e))

    class RevertSnapshotWorker(QThread):
        finished_ok = pyqtSignal(str)
        finished_err = pyqtSignal(str)

        def __init__(
            self,
            client: SynologyClient,
            lun_uuid: str,
            snapshot_uuid: str,
        ) -> None:
            super().__init__()
            self._client = client
            self._lun_uuid = lun_uuid
            self._snapshot_uuid = snapshot_uuid

        def run(self) -> None:
            try:
                self._client.revert_snapshot(self._lun_uuid, self._snapshot_uuid)
                self.finished_ok.emit(self._lun_uuid)
            except Exception as e:
                self.finished_err.emit(str(e))

    class DeleteLunWorker(QThread):
        """Delete all snapshots for a LUN, then delete the LUN (SYNO.Core.ISCSI.LUN API)."""

        finished_ok = pyqtSignal(str, int)
        finished_err = pyqtSignal(str)

        def __init__(self, client: SynologyClient, lun_uuid: str) -> None:
            super().__init__()
            self._client = client
            self._lun_uuid = lun_uuid

        def run(self) -> None:
            try:
                snaps = self._client.list_snapshots(self._lun_uuid)
                removed = 0
                if isinstance(snaps, list):
                    for s in snaps:
                        if not isinstance(s, dict):
                            continue
                        su = str(s.get("uuid") or "").strip()
                        if not su:
                            continue
                        self._client.delete_snapshot(su)
                        removed += 1
                self._client.delete_lun(self._lun_uuid)
                self.finished_ok.emit(self._lun_uuid, removed)
            except Exception as e:
                self.finished_err.emit(str(e))

    class ReloadLunsWorker(QThread):
        finished_ok = pyqtSignal(object)
        finished_err = pyqtSignal(str)

        def __init__(self, client: SynologyClient) -> None:
            super().__init__()
            self._client = client

        def run(self) -> None:
            try:
                luns = self._client.list_luns()
                self.finished_ok.emit(luns)
            except Exception as e:
                self.finished_err.emit(str(e))

    class TargetMappingWorker(QThread):
        finished_ok = pyqtSignal(int, object, object)
        finished_err = pyqtSignal(int, str)

        def __init__(
            self, client: SynologyClient, row: int, target_id: int, target: dict
        ) -> None:
            super().__init__()
            self._client = client
            self._row = row
            self._target_id = target_id
            self._target = target

        def run(self) -> None:
            merged: Optional[dict] = None
            t = dict(self._target)
            try:
                entries = mapped_lun_entries(t)
                if not entries:
                    gt: dict = {}
                    try:
                        gt = self._client.get_target(self._target_id, minimal=False)
                    except RuntimeError as e:
                        if "18990517" in str(e):
                            gt = self._client.get_target(self._target_id, minimal=True)
                        else:
                            raise
                    if gt:
                        merged = gt
                        t.update(gt)
                        entries = mapped_lun_entries(t)
                self.finished_ok.emit(self._row, entries, merged)
            except Exception as e:
                self.finished_err.emit(self._row, str(e))

    class Window(QWidget):
        def __init__(self) -> None:
            super().__init__()
            self.setWindowTitle("Synology LUN → Target")
            self.resize(720, 640)

            self._client: Optional[SynologyClient] = None
            self._targets: list[dict] = []
            self._lun_by_uuid: dict[str, dict] = {}
            self._busy = False
            self._lun_detail_seq = 0
            self._target_map_gen = 0
            self._connect_worker: Optional[ConnectWorker] = None
            self._create_worker: Optional[CreateWorker] = None
            self._lun_get_worker: Optional[LunGetWorker] = None
            self._resize_worker: Optional[LunResizeWorker] = None
            self._reload_worker: Optional[ReloadLunsWorker] = None
            self._target_map_worker: Optional[TargetMappingWorker] = None
            self._reload_reselect_uuid: Optional[str] = None
            self._lun_snapshot_allowed: Optional[bool] = None
            self._list_snapshots_worker: Optional[ListSnapshotsWorker] = None
            self._take_snapshot_worker: Optional[TakeSnapshotWorker] = None
            self._delete_snapshot_worker: Optional[DeleteSnapshotWorker] = None
            self._revert_snapshot_worker: Optional[RevertSnapshotWorker] = None
            self._delete_lun_worker: Optional[DeleteLunWorker] = None

            self.host = QLineEdit()
            self.port = QLineEdit()
            self.port.setText("5001")
            self.port.setMaximumWidth(100)
            self.https = QCheckBox("HTTPS")
            self.https.setChecked(True)
            self.verify_ssl = QCheckBox("Verify TLS certificate")
            self.user = QLineEdit()
            self.password = QLineEdit()
            self.password.setEchoMode(QLineEdit.EchoMode.Password)
            self.dsm_session = QLineEdit()
            self.btn_connect = QPushButton("Connect && refresh lists")
            self.target_list = QListWidget()
            self.target_list.setMinimumHeight(140)
            self.lun_list = QListWidget()
            self.lun_list.setMinimumHeight(140)
            self.lun_settings = QTextEdit()
            self.lun_settings.setReadOnly(True)
            self.lun_settings.setMinimumHeight(160)
            self.lun_edit_size_gib = QSpinBox()
            self.lun_edit_size_gib.setRange(1, 65536)
            self.lun_edit_size_gib.setEnabled(False)
            self.btn_apply_lun_size = QPushButton("Apply new size (expand)")
            self.btn_apply_lun_size.setEnabled(False)
            self.snapshot_combo = QComboBox()
            self.snapshot_combo.setMinimumWidth(260)
            self.snapshot_name = QLineEdit()
            self.snapshot_name.setPlaceholderText("New snapshot name")
            self.btn_take_snapshot = QPushButton("Take snapshot")
            self.btn_take_snapshot.setEnabled(False)
            self.btn_delete_snapshot = QPushButton("Delete selected snapshot")
            self.btn_delete_snapshot.setEnabled(False)
            self.btn_restore_snapshot = QPushButton("Restore selected snapshot…")
            self.btn_restore_snapshot.setEnabled(False)
            self.btn_restore_snapshot.setToolTip(
                "Reverts this LUN to the selected snapshot (SYNO revert_snapshot). "
                "Disconnect iSCSI initiators first; all newer data on the LUN is lost."
            )
            self.btn_delete_lun = QPushButton("Delete selected LUN…")
            self.btn_delete_lun.setEnabled(False)
            self.btn_delete_lun.setToolTip(
                "Removes all snapshots for this LUN, then deletes the LUN on the NAS. "
                "This cannot be undone."
            )
            self.btn_refresh_luns = QPushButton("Refresh LUN list from NAS")
            self.btn_refresh_luns.setEnabled(False)
            self.location_entry = QLineEdit()
            self.lun_name = QLineEdit()
            self.size_gib = QSpinBox()
            self.size_gib.setRange(1, 65536)
            self.size_gib.setValue(100)
            self.lun_type = QComboBox()
            self.lun_type.addItems(LUN_TYPES)
            self.lun_type.setCurrentText("ADV")
            self.lun_type.setToolTip(
                "Default is ADV (Ext4 thin / advanced feature set). On Btrfs pools use "
                "BLUN or BLUN_THICK instead. BLOCK (thick) is often rejected on Btrfs "
                "(API error 18991205); try THIN, FILE, or BLUN if create fails."
            )
            self.description = QLineEdit()
            self.description.setText("Created via synology_lun_gui")
            self.btn_create = QPushButton("Create LUN and attach to target")
            self.status = QTextEdit()
            self.status.setReadOnly(True)
            self.status.setMinimumHeight(120)

            conn = QFormLayout()
            conn.addRow("NAS host / IP", self.host)
            row_port = QHBoxLayout()
            row_port.addWidget(self.port)
            row_port.addWidget(self.https)
            row_port.addWidget(self.verify_ssl)
            row_port.addStretch()
            conn.addRow("DSM port", row_port)
            conn.addRow("Username", self.user)
            conn.addRow("Password", self.password)
            conn.addRow("Auth session (optional)", self.dsm_session)
            conn.addRow(self.btn_connect)

            targets_col = QVBoxLayout()
            targets_col.addWidget(QLabel("iSCSI targets"))
            targets_col.addWidget(self.target_list)
            luns_col = QVBoxLayout()
            luns_col.addWidget(QLabel("LUNs on selected target"))
            luns_col.addWidget(self.lun_list)
            tgt_lun_row = QHBoxLayout()
            tgt_lun_row.addLayout(targets_col, 1)
            tgt_lun_row.addLayout(luns_col, 1)

            detail = QFormLayout()
            detail.addRow("Settings", self.lun_settings)
            row_sz = QHBoxLayout()
            row_sz.addWidget(QLabel("New size (GiB, expand-only)"))
            row_sz.addWidget(self.lun_edit_size_gib)
            row_sz.addWidget(self.btn_apply_lun_size)
            row_sz.addWidget(self.btn_refresh_luns)
            row_sz.addStretch()
            detail.addRow(row_sz)
            row_snap = QHBoxLayout()
            row_snap.addWidget(QLabel("Snapshots"))
            row_snap.addWidget(self.snapshot_combo, 1)
            detail.addRow(row_snap)
            row_snap_act = QHBoxLayout()
            row_snap_act.addWidget(self.snapshot_name)
            row_snap_act.addWidget(self.btn_take_snapshot)
            row_snap_act.addWidget(self.btn_delete_snapshot)
            row_snap_act.addWidget(self.btn_restore_snapshot)
            row_snap_act.addStretch()
            detail.addRow(row_snap_act)
            row_del_lun = QHBoxLayout()
            row_del_lun.addWidget(self.btn_delete_lun)
            row_del_lun.addStretch()
            detail.addRow(row_del_lun)

            create = QFormLayout()
            create.addRow("LUN location", self.location_entry)
            create.addRow("New LUN name", self.lun_name)
            create.addRow("Size (GiB)", self.size_gib)
            create.addRow("LUN type", self.lun_type)
            create.addRow("Description", self.description)
            create.addRow(self.btn_create)

            scroll_inner = QWidget()
            inner = QVBoxLayout(scroll_inner)
            inner.addLayout(conn)
            inner.addWidget(QLabel("—"))
            inner.addLayout(tgt_lun_row)
            inner.addWidget(QLabel("Selected LUN"))
            inner.addLayout(detail)
            inner.addWidget(QLabel("—"))
            inner.addWidget(QLabel("Create new LUN on NAS && map to selected target"))
            inner.addLayout(create)
            inner.addStretch()

            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QScrollArea.Shape.NoFrame)
            scroll.setHorizontalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAsNeeded
            )
            scroll.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAsNeeded
            )
            scroll.setWidget(scroll_inner)

            root = QVBoxLayout(self)
            root.addWidget(scroll, 1)
            root.addWidget(QLabel("Status"))
            root.addWidget(self.status)

            self.btn_connect.clicked.connect(self._on_connect)
            self.btn_create.clicked.connect(self._on_create)
            self.target_list.currentRowChanged.connect(self._on_target_row_changed)
            self.lun_list.itemSelectionChanged.connect(self._on_lun_selection_changed)
            self.btn_apply_lun_size.clicked.connect(self._on_apply_lun_size)
            self.btn_refresh_luns.clicked.connect(self._on_refresh_luns)
            self.btn_take_snapshot.clicked.connect(self._on_take_snapshot)
            self.btn_delete_snapshot.clicked.connect(self._on_delete_snapshot)
            self.btn_restore_snapshot.clicked.connect(self._on_restore_snapshot)
            self.btn_delete_lun.clicked.connect(self._on_delete_lun)
            self.snapshot_combo.currentIndexChanged.connect(
                self._on_snapshot_combo_changed
            )

        def _log(self, msg: str) -> None:
            self.status.append(msg)

        def _refresh_lun_action_buttons(self) -> None:
            c = self._client is not None and not self._busy
            self.btn_refresh_luns.setEnabled(c)
            txt = self.lun_settings.toPlainText().strip()
            bad = (not txt) or txt.startswith("(failed to load")
            can_apply = (
                c
                and self.lun_list.currentItem() is not None
                and not bad
                and self.lun_edit_size_gib.isEnabled()
            )
            self.btn_apply_lun_size.setEnabled(can_apply)
            can_snap = (
                c
                and self.lun_list.currentItem() is not None
                and not bad
                and not txt.startswith("Loading")
                and self._lun_snapshot_allowed is not False
            )
            self.btn_take_snapshot.setEnabled(can_snap)
            if self._lun_snapshot_allowed is False:
                self.btn_take_snapshot.setToolTip(
                    "This LUN reports dev_attribs → can_snapshot with enable=0. "
                    "DSM will reject take_snapshot (often FILE LUNs on Btrfs; try "
                    "THIN on a volume where SAN Manager enables snapshots)."
                )
            else:
                self.btn_take_snapshot.setToolTip("")
            self._refresh_snapshot_action_buttons()
            can_delete_lun = c and self.lun_list.currentItem() is not None
            self.btn_delete_lun.setEnabled(can_delete_lun)

        def _refresh_snapshot_action_buttons(self) -> None:
            c = self._client is not None and not self._busy
            su = self.snapshot_combo.currentData()
            has_snap = isinstance(su, str) and len(su) > 0
            self.btn_delete_snapshot.setEnabled(c and has_snap)
            self.btn_restore_snapshot.setEnabled(c and has_snap)

        def _on_snapshot_combo_changed(self, _index: int) -> None:
            self._refresh_snapshot_action_buttons()

        def _set_busy(self, busy: bool) -> None:
            self._busy = busy
            self.btn_connect.setEnabled(not busy)
            self.btn_create.setEnabled(not busy and self._client is not None)
            if busy:
                self.btn_apply_lun_size.setEnabled(False)
                self.btn_refresh_luns.setEnabled(False)
                self.btn_take_snapshot.setEnabled(False)
                self.btn_delete_snapshot.setEnabled(False)
                self.btn_restore_snapshot.setEnabled(False)
                self.btn_delete_lun.setEnabled(False)
                self.lun_edit_size_gib.setEnabled(False)
            else:
                self._refresh_lun_action_buttons()
                if self.lun_list.currentItem() is not None and self.lun_settings.toPlainText().strip():
                    self.lun_edit_size_gib.setEnabled(True)

        def _parse_port(self) -> Optional[int]:
            raw = self.port.text().strip()
            if not raw:
                return None
            try:
                p = int(raw)
                return p if 1 <= p <= 65535 else None
            except ValueError:
                return None

        def _on_connect(self) -> None:
            if self._busy:
                return
            host = self.host.text().strip()
            if not host:
                QMessageBox.warning(self, "Connect", "Enter NAS host or IP.")
                return
            user = self.user.text().strip()
            pw = self.password.text()
            if not user or not pw:
                QMessageBox.warning(self, "Connect", "Enter username and password.")
                return
            p = self._parse_port()
            if self.port.text().strip() and p is None:
                QMessageBox.warning(self, "Connect", "Invalid port.")
                return

            self._set_busy(True)
            self.status.clear()
            self._log("Connecting…")

            use_https = self.https.isChecked()

            self._connect_worker = ConnectWorker(
                host,
                user,
                pw,
                use_https,
                p,
                self.verify_ssl.isChecked(),
                self.dsm_session.text().strip(),
            )
            self._connect_worker.finished_ok.connect(self._connect_done)
            self._connect_worker.finished_err.connect(self._connect_fail)
            self._connect_worker.start()

        def _connect_done(self, payload: object) -> None:
            c, targets, paths, luns = payload  # type: ignore[misc]
            self._client = c
            self._targets = targets if isinstance(targets, list) else []
            self._lun_by_uuid = {}
            if isinstance(luns, list):
                for lun in luns:
                    if isinstance(lun, dict):
                        u = lun.get("uuid") or lun.get("UUID")
                        if u:
                            self._lun_by_uuid[str(u)] = lun
            self.target_list.blockSignals(True)
            self.target_list.clear()
            for t in self._targets:
                if not isinstance(t, dict):
                    continue
                name = t.get("name") or ""
                tid = t.get("target_id")
                iqn = t.get("iqn") or ""
                lab = (
                    f"{name}  (id {tid}, {iqn[:48]}…)"
                    if len(str(iqn)) > 48
                    else f"{name}  (id {tid}, {iqn})"
                )
                self.target_list.addItem(lab)
            if self.target_list.count():
                self.target_list.setCurrentRow(0)
            self.target_list.blockSignals(False)
            self._refresh_lun_list_for_target()
            self.location_entry.clear()
            if paths and isinstance(paths, list) and paths:
                self.location_entry.setText(str(paths[0]))
            n_paths = len(paths) if isinstance(paths, list) else 0
            self._log(
                f"Loaded {len(self._targets)} target(s), "
                f"{len(self._lun_by_uuid)} LUN(s) on NAS, {n_paths} volume path(s)."
            )
            self._set_busy(False)

        def _connect_fail(self, msg: str) -> None:
            self._set_busy(False)
            self._lun_by_uuid.clear()
            self.lun_list.clear()
            self._clear_lun_detail()
            self._log(f"Error: {msg}")
            QMessageBox.critical(self, "Connect", msg)

        def _clear_lun_detail(self) -> None:
            self.lun_settings.clear()
            self.lun_edit_size_gib.setEnabled(False)
            self._lun_detail_seq += 1
            self._lun_snapshot_allowed = None
            self.btn_take_snapshot.setToolTip("")
            self.snapshot_combo.blockSignals(True)
            self.snapshot_combo.clear()
            self.snapshot_combo.blockSignals(False)
            self.snapshot_name.clear()
            self._refresh_lun_action_buttons()

        def _lun_entries_with_fallback(
            self, mapped: list[tuple[int, str]]
        ) -> tuple[list[tuple[int, str]], bool]:
            """
            If DSM omits mapped_lun data for this target, list every LUN we know
            from the global LUN list so the user can still open details / resize.
            Returns (entries, mapping_unknown).
            """
            if mapped:
                return mapped, False
            if self._lun_by_uuid:
                keys = sorted(self._lun_by_uuid.keys())
                self._log(
                    "SAN Manager did not report which LUNs are mapped to this "
                    f"target; listing all {len(keys)} LUN(s) from the NAS inventory."
                )
                return [(i, k) for i, k in enumerate(keys)], True
            return [], False

        def _fill_lun_list_from_entries(
            self,
            entries: list[tuple[int, str]],
            *,
            mapping_unknown: bool = False,
        ) -> None:
            for mi, u in entries:
                lun = self._lun_by_uuid.get(u, {})
                name = lun.get("name") if isinstance(lun, dict) else None
                if isinstance(name, str) and name.strip():
                    label = name.strip()
                else:
                    label = u[:8] + "…"
                slot = mi if mi >= 0 else 0
                if mapping_unknown:
                    txt = f"{label}  (#{slot + 1} on NAS — target mapping not in DSM data)"
                else:
                    txt = f"{label}  (target LUN index {slot})"
                item = QListWidgetItem(txt)
                item.setData(Qt.ItemDataRole.UserRole, u)
                self.lun_list.addItem(item)

        def _refresh_lun_list_for_target(self) -> None:
            self._target_map_gen += 1
            gen = self._target_map_gen
            self.lun_list.clear()
            self._clear_lun_detail()
            if not self._client:
                return
            row = self.target_list.currentRow()
            t, tid = self._selected_target()
            if not t or tid is None:
                return
            entries = mapped_lun_entries(t)
            if entries:
                self._fill_lun_list_from_entries(entries, mapping_unknown=False)
                return
            fb, unk = self._lun_entries_with_fallback([])
            if fb:
                self._fill_lun_list_from_entries(fb, mapping_unknown=unk)
            self._target_map_worker = TargetMappingWorker(
                self._client, row, tid, t
            )
            self._target_map_worker.finished_ok.connect(
                lambda r, ent, mg, g=gen: self._on_target_map_done(r, ent, mg, g)
            )
            self._target_map_worker.finished_err.connect(
                lambda r, msg, g=gen: self._on_target_map_err(r, msg, g)
            )
            self._target_map_worker.start()

        def _on_target_map_done(
            self, row: int, entries: object, merged: object, gen: int
        ) -> None:
            if gen != self._target_map_gen:
                return
            if isinstance(merged, dict) and merged and 0 <= row < len(self._targets):
                self._targets[row].update(merged)
            if self.target_list.currentRow() != row:
                return
            ent = normalize_lun_map_entries(entries)
            if ent:
                self.lun_list.clear()
                self._clear_lun_detail()
                self._fill_lun_list_from_entries(ent, mapping_unknown=False)
                return
            if self.lun_list.count() == 0:
                fb, unk = self._lun_entries_with_fallback([])
                self._fill_lun_list_from_entries(fb, mapping_unknown=unk)

        def _on_target_map_err(self, row: int, msg: str, gen: int) -> None:
            if gen != self._target_map_gen:
                return
            if self.target_list.currentRow() == row:
                self._log(f"Target LUN mapping lookup failed: {msg}")
                if self.lun_list.count() == 0:
                    fb, unk = self._lun_entries_with_fallback([])
                    self._fill_lun_list_from_entries(fb, mapping_unknown=unk)

        def _on_target_row_changed(self, row: int) -> None:
            if row < 0:
                self.lun_list.clear()
                self._clear_lun_detail()
                return
            self._refresh_lun_list_for_target()

        def _on_lun_selection_changed(self) -> None:
            item = self.lun_list.currentItem()
            if not item:
                self._clear_lun_detail()
                return
            u = item.data(Qt.ItemDataRole.UserRole)
            if not u:
                self._clear_lun_detail()
                return
            self._fetch_lun_detail(str(u))

        def _fetch_lun_detail(self, lun_uuid: str) -> None:
            if not self._client:
                return
            self.lun_settings.setPlainText("Loading…")
            self.lun_edit_size_gib.setEnabled(False)
            self._refresh_lun_action_buttons()
            self._lun_detail_seq += 1
            seq = self._lun_detail_seq
            self._lun_get_worker = LunGetWorker(self._client, seq, lun_uuid)
            self._lun_get_worker.finished_ok.connect(self._lun_get_done)
            self._lun_get_worker.finished_err.connect(self._lun_get_fail)
            self._lun_get_worker.start()

        def _start_list_snapshots(self, seq: int, lun_uuid: str) -> None:
            if not self._client:
                return
            self.snapshot_combo.blockSignals(True)
            self.snapshot_combo.clear()
            self.snapshot_combo.addItem("Loading snapshots…", "")
            self.snapshot_combo.blockSignals(False)
            self._refresh_snapshot_action_buttons()
            self._list_snapshots_worker = ListSnapshotsWorker(
                self._client, seq, lun_uuid
            )
            self._list_snapshots_worker.finished_ok.connect(
                self._snapshots_list_done
            )
            self._list_snapshots_worker.finished_err.connect(
                self._snapshots_list_fail
            )
            self._list_snapshots_worker.start()

        def _snapshots_list_done(self, seq: int, lun_uuid: str, snaps: object) -> None:
            if seq != self._lun_detail_seq:
                return
            cur = self.lun_list.currentItem()
            cu = cur.data(Qt.ItemDataRole.UserRole) if cur else None
            if str(cu or "") != lun_uuid:
                return
            self.snapshot_combo.blockSignals(True)
            self.snapshot_combo.clear()
            if isinstance(snaps, list):
                for s in snaps:
                    label, su = snapshot_list_item_label(
                        s if isinstance(s, dict) else {}
                    )
                    if su:
                        self.snapshot_combo.addItem(label, su)
            if self.snapshot_combo.count() == 0:
                self.snapshot_combo.addItem("(no snapshots)", "")
            self.snapshot_combo.blockSignals(False)
            self._refresh_snapshot_action_buttons()

        def _snapshots_list_fail(self, seq: int, lun_uuid: str, msg: str) -> None:
            if seq != self._lun_detail_seq:
                return
            cur = self.lun_list.currentItem()
            cu = cur.data(Qt.ItemDataRole.UserRole) if cur else None
            if str(cu or "") != lun_uuid:
                return
            self.snapshot_combo.blockSignals(True)
            self.snapshot_combo.clear()
            self.snapshot_combo.addItem(f"(failed: {msg[:60]})", "")
            self.snapshot_combo.blockSignals(False)
            self._log(f"List snapshots: {msg}")
            self._refresh_snapshot_action_buttons()

        def _lun_get_done(self, seq: int, uuid: str, lun: object) -> None:
            if seq != self._lun_detail_seq:
                return
            cur = self.lun_list.currentItem()
            cu = cur.data(Qt.ItemDataRole.UserRole) if cur else None
            if str(cu or "") != uuid:
                return
            if not isinstance(lun, dict) or not lun:
                self.lun_settings.setPlainText("(empty response from NAS)")
                self._lun_snapshot_allowed = None
                self._refresh_lun_action_buttons()
                self._start_list_snapshots(seq, uuid)
                return
            self._lun_by_uuid[uuid] = lun
            self._lun_snapshot_allowed = lun_snapshot_allowed_by_dsm(lun)
            if self._lun_snapshot_allowed is False:
                self._log(
                    "This LUN has can_snapshot=0 in dev_attribs — DSM will not allow "
                    "new snapshots (take_snapshot typically returns 18990500). "
                    "Use a LUN type/volume combination SAN Manager supports for snapshots."
                )
            self.lun_settings.setPlainText(lun_settings_text(lun))
            b = lun_size_bytes(lun) or 0
            min_gib = max(1, math.ceil(b / (1024**3))) if b > 0 else 1
            self.lun_edit_size_gib.setMinimum(min_gib)
            self.lun_edit_size_gib.setMaximum(65536)
            self.lun_edit_size_gib.setValue(min_gib)
            if not self._busy:
                self.lun_edit_size_gib.setEnabled(True)
            self._refresh_lun_action_buttons()
            self._start_list_snapshots(seq, uuid)

        def _lun_get_fail(self, seq: int, msg: str) -> None:
            if seq != self._lun_detail_seq:
                return
            cur = self.lun_list.currentItem()
            if not cur:
                return
            self.lun_settings.setPlainText(f"(failed to load LUN)\n{msg}")
            self.lun_edit_size_gib.setEnabled(False)
            self._lun_snapshot_allowed = None
            self.snapshot_combo.blockSignals(True)
            self.snapshot_combo.clear()
            self.snapshot_combo.blockSignals(False)
            self._log(f"LUN get error: {msg}")
            self._refresh_lun_action_buttons()

        def _on_take_snapshot(self) -> None:
            if self._busy or not self._client:
                return
            item = self.lun_list.currentItem()
            if not item:
                return
            lun_uuid = str(item.data(Qt.ItemDataRole.UserRole) or "")
            if not lun_uuid:
                return
            if self._lun_snapshot_allowed is False:
                QMessageBox.information(
                    self,
                    "Snapshot",
                    "This LUN reports can_snapshot=0. DSM does not allow snapshots "
                    "for this LUN/volume (take_snapshot would fail).",
                )
                return
            name = self.snapshot_name.text().strip()
            if not name:
                QMessageBox.warning(
                    self,
                    "Snapshot",
                    "Enter a name for the new snapshot.",
                )
                return
            if any(ch.isspace() for ch in name):
                QMessageBox.warning(
                    self,
                    "Snapshot",
                    "Snapshot names should not contain whitespace "
                    "(use hyphens or underscores if DSM rejects spaces).",
                )
                return
            self._set_busy(True)
            self._log(f"Taking snapshot “{name}” on LUN {lun_uuid[:8]}…")
            self._take_snapshot_worker = TakeSnapshotWorker(
                self._client,
                lun_uuid,
                name,
                f"synology_lun_gui: {name}",
            )
            self._take_snapshot_worker.finished_ok.connect(self._take_snapshot_done)
            self._take_snapshot_worker.finished_err.connect(
                self._take_snapshot_fail
            )
            self._take_snapshot_worker.start()

        def _take_snapshot_done(self, lun_uuid: str) -> None:
            self._set_busy(False)
            self._log(f"Snapshot created for LUN {lun_uuid[:8]}…")
            QMessageBox.information(self, "Snapshot", "Snapshot created.")
            self.snapshot_name.clear()
            if self._client:
                self._start_list_snapshots(self._lun_detail_seq, lun_uuid)

        def _take_snapshot_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(
                    self, "Snapshot", "Session expired. Connect again."
                )
                return
            self._log(f"Snapshot error: {msg}")
            QMessageBox.critical(self, "Snapshot", msg)

        def _on_delete_snapshot(self) -> None:
            if self._busy or not self._client:
                return
            item = self.lun_list.currentItem()
            if not item:
                return
            lun_uuid = str(item.data(Qt.ItemDataRole.UserRole) or "")
            snap_uuid = self.snapshot_combo.currentData()
            if not isinstance(snap_uuid, str) or not snap_uuid:
                return
            snap_label = self.snapshot_combo.currentText()
            r = QMessageBox.question(
                self,
                "Delete snapshot",
                f"Delete this snapshot?\n\n{snap_label}",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if r != QMessageBox.StandardButton.Yes:
                return
            self._set_busy(True)
            self._log(f"Deleting snapshot {snap_uuid[:8]}…")
            self._delete_snapshot_worker = DeleteSnapshotWorker(
                self._client, lun_uuid, snap_uuid
            )
            self._delete_snapshot_worker.finished_ok.connect(
                self._delete_snapshot_done
            )
            self._delete_snapshot_worker.finished_err.connect(
                self._delete_snapshot_fail
            )
            self._delete_snapshot_worker.start()

        def _delete_snapshot_done(self, lun_uuid: str) -> None:
            self._set_busy(False)
            self._log(f"Snapshot deleted for LUN {lun_uuid[:8]}…")
            QMessageBox.information(self, "Snapshot", "Snapshot deleted.")
            if self._client:
                self._start_list_snapshots(self._lun_detail_seq, lun_uuid)

        def _delete_snapshot_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(
                    self, "Snapshot", "Session expired. Connect again."
                )
                return
            self._log(f"Delete snapshot error: {msg}")
            QMessageBox.critical(self, "Snapshot", msg)

        def _on_restore_snapshot(self) -> None:
            if self._busy or not self._client:
                return
            item = self.lun_list.currentItem()
            if not item:
                return
            lun_uuid = str(item.data(Qt.ItemDataRole.UserRole) or "")
            snap_uuid = self.snapshot_combo.currentData()
            if not isinstance(snap_uuid, str) or not snap_uuid:
                return
            snap_label = self.snapshot_combo.currentText()
            msg = (
                f"Restore this LUN to the following snapshot?\n\n{snap_label}\n\n"
                "The LUN will be reverted to that point in time. All newer data on "
                "the LUN will be lost.\n\n"
                "Disconnect iSCSI initiators (unmount VMs/disks) before restoring "
                "to avoid data corruption."
            )
            r = QMessageBox.warning(
                self,
                "Restore snapshot",
                msg,
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if r != QMessageBox.StandardButton.Yes:
                return
            self._set_busy(True)
            self._log(f"Restoring LUN {lun_uuid[:8]}… from snapshot {snap_uuid[:8]}…")
            self._revert_snapshot_worker = RevertSnapshotWorker(
                self._client, lun_uuid, snap_uuid
            )
            self._revert_snapshot_worker.finished_ok.connect(
                self._restore_snapshot_done
            )
            self._revert_snapshot_worker.finished_err.connect(
                self._restore_snapshot_fail
            )
            self._revert_snapshot_worker.start()

        def _restore_snapshot_done(self, lun_uuid: str) -> None:
            self._set_busy(False)
            self._log(f"LUN {lun_uuid[:8]}… restored from snapshot.")
            QMessageBox.information(
                self, "Restore snapshot", "LUN restored from the selected snapshot."
            )
            if self._client:
                self._fetch_lun_detail(lun_uuid)

        def _restore_snapshot_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(
                    self, "Restore snapshot", "Session expired. Connect again."
                )
                return
            self._log(f"Restore snapshot error: {msg}")
            QMessageBox.critical(self, "Restore snapshot", msg)

        def _on_delete_lun(self) -> None:
            if self._busy or not self._client:
                return
            item = self.lun_list.currentItem()
            if not item:
                return
            lun_uuid = str(item.data(Qt.ItemDataRole.UserRole) or "")
            if not lun_uuid:
                return
            lun = self._lun_by_uuid.get(lun_uuid, {})
            disp = lun_uuid
            if isinstance(lun, dict):
                n = lun.get("name")
                if isinstance(n, str) and n.strip():
                    disp = n.strip()
            msg = (
                f'Permanently delete the LUN "{disp}" from the NAS?\n\n'
                "If this LUN has snapshots, they will be deleted first, then the LUN "
                "will be removed. Connected hosts may lose access to this storage.\n\n"
                "This action cannot be reversed."
            )
            r = QMessageBox.warning(
                self,
                "Delete LUN",
                msg,
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if r != QMessageBox.StandardButton.Yes:
                return
            self._set_busy(True)
            self._log(
                f"Deleting LUN {lun_uuid[:8]}… (removing snapshots first if any)…"
            )
            self._delete_lun_worker = DeleteLunWorker(self._client, lun_uuid)
            self._delete_lun_worker.finished_ok.connect(self._delete_lun_done)
            self._delete_lun_worker.finished_err.connect(self._delete_lun_fail)
            self._delete_lun_worker.start()

        def _delete_lun_done(self, lun_uuid: str, snapshots_removed: int) -> None:
            self._set_busy(False)
            self._lun_by_uuid.pop(lun_uuid, None)
            if snapshots_removed:
                self._log(
                    f"LUN {lun_uuid[:8]}… deleted ({snapshots_removed} snapshot(s) removed)."
                )
            else:
                self._log(f"LUN {lun_uuid[:8]}… deleted (no snapshots).")
            QMessageBox.information(
                self,
                "Delete LUN",
                "The LUN has been deleted on the NAS.",
            )
            self._begin_lun_reload(select_uuid=None)

        def _delete_lun_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(
                    self, "Delete LUN", "Session expired. Connect again."
                )
                return
            self._log(f"Delete LUN error: {msg}")
            QMessageBox.critical(self, "Delete LUN", msg)

        def _on_refresh_luns(self) -> None:
            if self._busy or not self._client:
                return
            cur = self.lun_list.currentItem()
            self._reload_reselect_uuid = (
                str(cur.data(Qt.ItemDataRole.UserRole)) if cur else None
            )
            self._set_busy(True)
            self._log("Refreshing LUN inventory from NAS…")
            self._reload_worker = ReloadLunsWorker(self._client)
            self._reload_worker.finished_ok.connect(self._reload_done)
            self._reload_worker.finished_err.connect(self._reload_fail)
            self._reload_worker.start()

        def _reload_done(self, luns: object) -> None:
            self._set_busy(False)
            if not isinstance(luns, list):
                self._log("Refresh: unexpected response.")
                self._reload_reselect_uuid = None
                return
            self._lun_by_uuid = {}
            for lun in luns:
                if not isinstance(lun, dict):
                    continue
                u = lun.get("uuid") or lun.get("UUID")
                if u:
                    self._lun_by_uuid[str(u)] = lun
            prefer = self._reload_reselect_uuid
            self._reload_reselect_uuid = None
            self._refresh_lun_list_for_target()
            if prefer:
                for i in range(self.lun_list.count()):
                    it = self.lun_list.item(i)
                    if str(it.data(Qt.ItemDataRole.UserRole) or "") == prefer:
                        self.lun_list.setCurrentRow(i)
                        break
            self._log(
                f"LUN list refreshed ({len(self._lun_by_uuid)} LUN(s) total on NAS)."
            )

        def _reload_fail(self, msg: str) -> None:
            self._set_busy(False)
            self._reload_reselect_uuid = None
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(self, "Refresh", "Session expired. Connect again.")
                return
            self._log(f"Refresh error: {msg}")
            QMessageBox.critical(self, "Refresh", msg)

        def _on_apply_lun_size(self) -> None:
            if self._busy or not self._client:
                return
            item = self.lun_list.currentItem()
            if not item:
                return
            uuid = str(item.data(Qt.ItemDataRole.UserRole) or "")
            if not uuid:
                return
            new_gib = self.lun_edit_size_gib.value()
            new_bytes = new_gib * 1024 * 1024 * 1024
            prev = lun_size_bytes(self._lun_by_uuid.get(uuid, {})) or 0
            if new_bytes <= prev:
                QMessageBox.information(
                    self,
                    "Resize",
                    "New size must be larger than the current LUN capacity.",
                )
                return
            self._set_busy(True)
            self._log(f"Resizing LUN {uuid[:8]}… to {new_gib} GiB…")
            self._resize_worker = LunResizeWorker(self._client, uuid, new_bytes)
            self._resize_worker.finished_ok.connect(self._resize_done)
            self._resize_worker.finished_err.connect(self._resize_fail)
            self._resize_worker.start()

        def _resize_done(self, lun_uuid: str) -> None:
            self._set_busy(False)
            self._log(f"Resize OK for LUN {lun_uuid[:8]}…")
            QMessageBox.information(self, "Resize", "LUN size updated.")
            if self._client:
                self._fetch_lun_detail(lun_uuid)

        def _resize_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(self, "Resize", "Session expired. Connect again.")
                return
            self._log(f"Resize error: {msg}")
            QMessageBox.critical(self, "Resize", msg)

        def _begin_lun_reload(self, select_uuid: Optional[str]) -> None:
            if not self._client:
                return
            self._reload_reselect_uuid = select_uuid
            self._set_busy(True)
            self._log("Reloading LUN list…")
            self._reload_worker = ReloadLunsWorker(self._client)
            self._reload_worker.finished_ok.connect(self._reload_done)
            self._reload_worker.finished_err.connect(self._reload_fail)
            self._reload_worker.start()

        def _selected_target(self):
            row = self.target_list.currentRow()
            if row < 0 or row >= len(self._targets):
                return None, None
            t = self._targets[row]
            if not isinstance(t, dict):
                return None, None
            tid = t.get("target_id")
            try:
                return t, int(tid)
            except (TypeError, ValueError):
                return None, None

        def _on_create(self) -> None:
            if self._busy:
                return
            if not self._client:
                QMessageBox.information(self, "Create", "Connect first.")
                return
            _, tid = self._selected_target()
            if tid is None:
                QMessageBox.warning(self, "Create", "Select a target.")
                return
            loc = self.location_entry.text().strip()
            if not loc:
                QMessageBox.warning(self, "Create", "Set LUN location (e.g. /volume1).")
                return
            name = self.lun_name.text().strip()
            if not name:
                QMessageBox.warning(self, "Create", "Enter a LUN name.")
                return
            if any(ch.isspace() for ch in name):
                QMessageBox.warning(
                    self,
                    "Create",
                    "LUN names cannot contain spaces or other whitespace "
                    "(Synology DSM rejects them; e.g. error 18990503).\n\n"
                    "Use hyphens or underscores instead, e.g. Test-Target or Test_Target.",
                )
                return
            gib = self.size_gib.value()
            if gib < 1:
                QMessageBox.warning(self, "Create", "Size must be at least 1 GiB.")
                return
            size_bytes = gib * 1024 * 1024 * 1024
            lun_type = self.lun_type.currentText().strip() or "ADV"
            desc = self.description.text().strip() or " "

            self._set_busy(True)
            snap_note = (
                "; dev_attribs can_snapshot=1"
                if lun_type in LUN_TYPES_REQUEST_CAN_SNAPSHOT_AT_CREATE
                else ""
            )
            self._log(f"Creating LUN “{name}” ({gib} GiB, {lun_type}){snap_note}…")

            self._create_worker = CreateWorker(
                self._client,
                name=name,
                size_bytes=size_bytes,
                lun_type=lun_type,
                location=loc,
                description=desc,
                target_id=tid,
            )
            self._create_worker.finished_ok.connect(self._create_done)
            self._create_worker.finished_err.connect(self._create_fail)
            self._create_worker.start()

        def _create_done(self, uuid: str) -> None:
            self._set_busy(False)
            self._log(f"Done. LUN uuid: {uuid}")
            QMessageBox.information(self, "Create", f"LUN created and mapped.\n\nuuid: {uuid}")
            self._begin_lun_reload(select_uuid=str(uuid))

        def _create_fail(self, msg: str) -> None:
            self._set_busy(False)
            if msg == "SESSION_EXPIRED":
                self._log("Session expired; connect again.")
                QMessageBox.critical(self, "Create", "Session expired. Connect again.")
                return
            self._log(f"Error: {msg}")
            QMessageBox.critical(self, "Create", msg)

    os.environ.setdefault("QT_MAC_WANTS_LAYER", "1")
    app = QApplication(sys.argv)
    fusion = QStyleFactory.create("Fusion")
    if fusion is not None:
        app.setStyle(fusion)
    app.setStyleSheet(_HIGH_CONTRAST_QSS)
    w = Window()
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
