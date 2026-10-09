<div align="center">

# VexOS Helper Scripts

**One-line installers and utilities for Proxmox, NixOS, and friends.**

[![License](https://img.shields.io/github/license/VictoryTek/VexOS-Helper-Scripts?style=flat-square&color=blue)](LICENSE)
[![Scripts](https://img.shields.io/badge/scripts-4-brightgreen?style=flat-square)](#scripts)
[![Platform](https://img.shields.io/badge/platform-Proxmox%20%C2%B7%20NixOS%20%C2%B7%20Linux-lightgrey?style=flat-square)](#scripts)

[Scripts](#scripts) · [Usage](#usage) · [Contributing](#contributing) · [License](#license)

</div>

---

## Scripts

| Script | Runs on | Description |
| --- | --- | --- |
| [🏠 Home Assistant OS VM](#-home-assistant-os-vm) | Proxmox VE (proxmox-nixos) | Create a Home Assistant OS virtual machine |
| [🎬 Plex Migrate Backup](#-plex-migrate-backup) | Any systemd Linux | Snapshot Plex data into one portable `tar.gz` |
| [💾 Backup & Restore Docker Stacks](#-backup--restore-docker-stacks) | Any Linux with Docker | Menu-driven backup/restore of Dockge/docker-compose stacks |
| [🔀 Migrate Services to vexos](#-migrate-services-to-vexos) | vexos-nix server | Restore Docker Compose service backups into native vexos server modules |

---

### 🏠 Home Assistant OS VM

Creates a Home Assistant OS VM on a Proxmox VE host. Adapted for **proxmox-nixos**: automatically pulls in `whiptail`, `pv`, and `xz` via a temporary `nix-shell` if they're not already installed.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/home-assistant-os.sh)"
```

> [!NOTE]
> Run as **root** on the Proxmox host itself, not inside a container or VM.

---

### 🎬 Plex Migrate Backup

Stops `plex.service`, archives `/var/lib/plex` into a single portable `tar.gz`, verifies the archive, then restarts Plex. Ideal for moving a Plex server to a new host such as a vexos-nix machine.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/plex-migrate-backup.sh)"
```

Optionally pass a destination path (default: `./plex-backup-<timestamp>.tar.gz`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/plex-migrate-backup.sh)" _ /mnt/backups/plex.tar.gz
```

> [!NOTE]
> Run on the Plex server itself. Requires `sudo` and a systemd-based install with `plex.service`. Plex is briefly stopped while the archive is created.

---

### 💾 Backup & Restore Docker Stacks

One script, two modes, picked from a menu (or by passing `backup`/`restore` as an argument):

- **Backup** — walks every stack under `STACKS_DIR` (e.g. a Dockge stacks folder) and, for each one: runs the app's own backup command if it's listed in `services.conf` (`method=builtin` — a Gitea dump, Paperless `document_exporter`, etc.), or otherwise auto-detects a Postgres/MySQL/Redis container and dumps it. It then stops the stack, archives the stack directory (compose file, `.env`, bind mounts, backup artifact/DB dump) into `BACKUP_DIR`, and restarts it. Optionally rsyncs the finished backup set to a remote host.
- **Restore** — for each `.tar.gz` dropped next to the script: extracts it (stack folder plus any captured bind-mount paths, back to their original absolute locations), recreates any Docker networks the compose file marks `external: true`, then brings the stack back up — replaying the matching `services.conf` builtin restore command, or restoring the auto-detected DB dump, before starting the rest of the stack.

```bash
curl -fsSLO https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/backup-restore-services.sh && chmod +x backup-restore-services.sh && sudo ./backup-restore-services.sh
```

That downloads the script into the current folder, makes it executable, and runs it (interactive menu) — `sudo` will ask for your password. To skip the menu, or to run it again later:

```bash
sudo ./backup-restore-services.sh backup
sudo ./backup-restore-services.sh restore
```

**Which folder to run it from** — the script uses its own location as its working area, so it matters for restore but not for backup:

- **Backup:** any folder you can write to (Downloads, Documents, your home folder…). `STACKS_DIR` and `BACKUP_DIR` are absolute paths, so the current folder doesn't affect them. If you have a `services.conf`, put it in the same folder as the script first; backup copies it into `BACKUP_DIR`.
- **Restore:** run it from the folder that holds the backup set. It picks up the `.tar.gz` archives and `services.conf` from its own folder, and writes the restored stacks to a `stacks/` subfolder and `restore.log` there — so that folder needs enough free space for the restored stacks.

> [!NOTE]
> This isn't a curl-pipe-to-shell script — the one-liner above runs it with the defaults at the top of the file. If `STACKS_DIR`, `BACKUP_DIR`, or (optionally) `REMOTE_HOST` / `REMOTE_PATH` / `DO_REMOTE_SYNC` need changing, run only the `curl … && chmod +x …` part, edit the file, then start it with `sudo ./backup-restore-services.sh`. Run either mode as **root** (needs `docker compose down`/`up`) — the script exits immediately if it isn't. Backup produces `manifest.csv` (per-stack status) and `backup.log` in `BACKUP_DIR`; restore produces `restore.log` next to the script — review the relevant log afterward, especially any stack flagged for manual follow-up.

#### Configuring services.conf

Both modes look for an optional `services.conf` next to the script (backup copies its own copy into `BACKUP_DIR` so it travels with the archives). Each non-comment, non-blank line describes one stack:

```
stack_name|container|method|backup_cmd|artifact_path|restore_cmd
```

- `method` is `builtin` (run the app's own backup/restore commands) or left blank for the generic Postgres/MySQL/Redis auto-detection.
- `backup_cmd` / `restore_cmd` run inside `container` via `docker exec`; `artifact_path` is the in-container path copied out on backup and back in on restore.
- A stack with no matching line (or no `services.conf` at all) falls back to the generic DB-detection path.

---

### 🔀 Migrate Services to vexos

Takes a backup made by [Backup & Restore Docker Stacks](#-backup--restore-docker-stacks) (the zip, or a folder of `.tar.gz` files) and moves the services in it onto the matching `vexos.server.*` modules on a vexos-nix server. Only services **found in the backup** are touched. For each one it:

1. enables the module in `/etc/nixos/server-services.nix`
2. runs `just rebuild`
3. stops the service, moves any existing data aside (`<dest>.pre-restore-<time>`), copies the backed-up data into the module's real data location, fixes ownership, and starts it again

Supported: sonarr, radarr, lidarr, prowlarr, sabnzbd, bazarr, maintainerr, tautulli, code-server, wishlist, grimmory (including its database dump). qbittorrent, bookshelf and cloudflare-ddns are reported but not migrated. It never runs the backup script's restore mode or starts compose stacks.

```bash
curl -fsSLO https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/migrate-services.sh && chmod +x migrate-services.sh
chmod +x migrate-services.sh
./migrate-services.sh ~/Documents/vmc01-migration.zip           # look first
./migrate-services.sh --apply ~/Documents/vmc01-migration.zip   # then go
```

| Option | Effect |
| --- | --- |
| `--apply` | Actually make changes (default is a dry run) |
| `--only a,b,c` / `--skip a,b` | Limit to, or leave out, specific services |
| `--skip-rebuild` | Don't run `just rebuild` |
| `--force` | Redo a service already migrated by this script |
| `--repo DIR` | Location of your vexos-nix checkout (the folder with the `justfile`) |
| `--services-file F` | Default `/etc/nixos/server-services.nix` |
| `--keep-staging` | Keep the extracted backup when finished |

> [!NOTE]
> Run as your **normal user** on the vexos server (it uses `sudo` where needed). Start with the dry run. code-server is only enabled once `vexos.server.code-server.hashedPassword` is set. After migrating, check the Arr apps' download clients and root folders and Tautulli's Plex address, since they still point at the old container setup.

---

## Usage

Every script installs with a single command: copy it, paste it into a shell, done.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/<script-name>.sh)"
```

Prefer to read before you run? Download the script and inspect it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/<script-name>.sh
less <script-name>.sh
bash <script-name>.sh
```

> [!WARNING]
> Never pipe a script you haven't reviewed into a root shell. Every script lives in [`scripts/`](scripts/) and is short enough to read.

## Contributing

Issues and pull requests are welcome. New scripts go in [`scripts/`](scripts/), and should include a short header comment describing what they do, plus an entry in the [Scripts](#scripts) section above.

## License

Released under the [MIT License](LICENSE).
