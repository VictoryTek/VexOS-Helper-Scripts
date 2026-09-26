<div align="center">

# VexOS Helper Scripts

**One-line installers and utilities for Proxmox, NixOS, and friends.**

[![License](https://img.shields.io/github/license/VictoryTek/VexOS-Helper-Scripts?style=flat-square&color=blue)](LICENSE)
[![Scripts](https://img.shields.io/badge/scripts-2-brightgreen?style=flat-square)](#scripts)
[![Platform](https://img.shields.io/badge/platform-Proxmox%20%C2%B7%20NixOS%20%C2%B7%20Linux-lightgrey?style=flat-square)](#scripts)

[Scripts](#scripts) · [Usage](#usage) · [Contributing](#contributing) · [License](#license)

</div>

---

## Scripts

| Script | Runs on | Description |
| --- | --- | --- |
| [🏠 Home Assistant OS VM](#-home-assistant-os-vm) | Proxmox VE (proxmox-nixos) | Create a Home Assistant OS virtual machine |
| [🎬 Plex Migrate Backup](#-plex-migrate-backup) | Any systemd Linux | Snapshot Plex data into one portable `tar.gz` |

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
