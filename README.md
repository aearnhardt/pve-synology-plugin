# Proxmox VE — Synology iSCSI storage plugin

**Repository:** [github.com/aearnhardt/pve-synology-plugin](https://github.com/aearnhardt/pve-synology-plugin)

Perl custom storage plugin (`synology`) that automates **Synology DSM** iSCSI LUN lifecycle from Proxmox: create/delete/resize, map LUNs to an existing **iSCSI target**, **snapshots**, **clone from snapshot**, and **raw+size** import/export.

Derived from the same Proxmox integration patterns as [pve-nimble-plugin](https://github.com/brngates98/pve-nimble-plugin). DSM calls follow the Web API usage in Synology’s open-source CSI driver (`SYNO.Core.ISCSI.LUN`, `SYNO.Core.ISCSI.Target`, `SYNO.API.Auth`).

## Requirements

- Proxmox VE 8.x / 9.x with `libpve-storage-perl`
- Synology DSM with **SAN Manager / iSCSI Target** enabled
- A DSM user account allowed to use the iSCSI / storage APIs (typically admin)
- **Pre-created iSCSI target** whose **name** matches `target_name` (the plugin maps new LUNs to this target)
- Initiator access: allow your Proxmox nodes’ IQNs on that target (or “Allow all initiators” for lab use)
- `open-iscsi`, `multipath-tools` on nodes (same class of setup as Nimble iSCSI)

## Install

**Unified installer (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh
```

The unified installer can:

- Install the plugin file to `/usr/share/perl5/PVE/Storage/Custom/SynologyStoragePlugin.pm`
- Restart the needed Proxmox services (`pve-cluster`, `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`)
- Launch interactive storage setup (`pvesm add synology ...`)
- Show status and uninstall from its interactive menu

When run from a local clone, `install.sh` prefers a local `./SynologyStoragePlugin.pm` first. If that file is not present (or if `--plugin-url` is set), it fetches from GitHub.

Useful flags:

- `--menu` / `--no-menu`
- `--configure` / `--no-configure`
- `--repo-base <url>` / `--plugin-url <url>` / `--dest <path>`
- `--yes` (non-interactive confirmations)

**Legacy direct installer:** you can still run:

```bash
curl -fsSL https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main/scripts/install-pve-synology-plugin.sh | sudo bash
```

**Manual:** copy `SynologyStoragePlugin.pm` to `/usr/share/perl5/PVE/Storage/Custom/` on each node, or build and install the Debian package **`libpve-storage-synology-perl`** from `debian/`, then restart `pvedaemon`, `pvestatd`, `pveproxy`.

## Configure storage

### Interactive setup

On each Proxmox node (as **root**), after the plugin is installed, you can run either helper:

- `install.sh` (main menu option: **Configure Synology storage**)
- `scripts/configure-pve-synology-storage.sh` (direct configure flow)

Both prompt for required values and optional advanced settings, show a redacted preview of the `pvesm` command, then run `pvesm add` if you confirm.

From GitHub (replace `main` if you use another branch):

```bash
curl -fsSL https://raw.githubusercontent.com/aearnhardt/pve-synology-plugin/main/scripts/configure-pve-synology-storage.sh -o /tmp/configure-pve-synology-storage.sh
sudo bash /tmp/configure-pve-synology-storage.sh
```

From a local clone of this repository:

```bash
sudo ./scripts/configure-pve-synology-storage.sh
```

Set `DRY_RUN=1` to print the preview only and skip `pvesm` (still enter answers at the prompts).

**DSM password:** Proxmox treats `password` as sensitive for all storage types by default. The plugin also **removes** any password from the config object in `check_config` after writing it to `/etc/pve/priv/storage/<id>.pw` (and the other priv paths the plugin uses), so it should not appear in `storage.cfg` even when using `pvesm add --password`. **Do not** declare `'sensitive-properties' => {}` in `plugindata` — an empty hash is still “true” in Perl, and Proxmox would then treat **no** properties as sensitive (including password). If an old `password` line is still in `storage.cfg`, run `pvesm set <id> --password '<same>'` once to rewrite the section, or remove that line after confirming the priv files hold the secret.

### Manual (`pvesm add`)

```bash
pvesm add synology <storage-id> \
  --address <nas-hostname-or-ip> \
  --username <dsm-user> \
  --password <dsm-password> \
  --target_name "<exact target name in DSM>" \
  --lun_location /volume1 \
  --content images
```

Useful options:

| Option | Purpose |
|--------|--------|
| `use_https` / `dsm_port` | DSM API (default HTTPS port 5001) |
| `check_ssl` | Set `yes` if using a proper TLS cert on DSM |
| `lun_type` | e.g. `THIN`, `BLUN` (pool-dependent) |
| `iscsi_discovery_ips` | Comma-separated `host:3260` if iSCSI should not use `address` |
| `auto_iscsi_discovery` | `no` to skip sendtargets/login on activate |
| `dsm_session` | Some accounts need `session` on login (try if login fails) |

## Caveats

- **DSM and model differences**: API behaviour and required `lun_type` / `lun_location` vary by DSM version and NAS series; validate on your unit.
- **LUN size units**: Create/resize send size in **bytes** to DSM (aligned with typical CSI usage). If your firmware expects different units, adjust `alloc_image` / `volume_resize` accordingly.
- **Snapshot rollback** uses DSM method `revert_snapshot`; confirm it exists on your DSM (otherwise rollback tasks will fail with a DSM error code).
- **Disk matching** uses the LUN **UUID** (hex, no hyphens) to find `/dev/disk/by-id` entries; exotic setups may need extra heuristics.
- **Volume rename** is not implemented (`rename_volume` dies).

## Optional: DSM GUI helper

The repository includes **`tools/synology-lun-gui/`**, a standalone Python/PyQt6 utility that talks to the same DSM iSCSI APIs as the plugin (list LUNs, resize, snapshots, etc.). It is **not** required for Proxmox; use it only if you want a desktop helper for DSM. See the script docstring and `requirements.txt` in that directory.

I built this as I was working thru problems due to ProxMox and Synology not using the same terminology for some things.  I just left it in here as it can save you some time vs logging into DSM for some tasks.

## Disclaimer (AS-IS)

This project is provided **“AS IS”** and **without warranty of any kind**, whether express, implied, or statutory, including—without limitation—implied warranties of merchantability, fitness for a particular purpose, title, and non-infringement. The authors and contributors do not warrant that the software will be uninterrupted, error-free, or suitable for your hardware, DSM version, or Proxmox configuration.

**Use at your own risk.** Storage plugins can affect live VMs, LUNs, snapshots, and data paths. You are solely responsible for backups, change control, testing in non-production environments, and compliance with Synology and Proxmox documentation and support policies. **In no event** shall the authors or copyright holders be liable for any direct, indirect, incidental, special, exemplary, or consequential damages (including loss of data, downtime, or business interruption) arising from use or inability to use this software, even if advised of the possibility of such damages.
