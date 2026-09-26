#!/usr/bin/env bash
# Snapshot a Plex Media Server's data directory (/var/lib/plex) to a single
# portable tar.gz, suitable for moving to a new server (e.g. a vexos-nix
# Plex host). Mirrors the `backup-plex` just recipe in vexos-nix, adapted
# to run standalone on any systemd-based Linux Plex install.
#
# Usage: ./plex-migrate-backup.sh [dest.tar.gz]

set -euo pipefail

if ! systemctl list-unit-files plex.service &>/dev/null; then
    echo "error: plex.service not found on this system." >&2
    exit 1
fi

DEST="${1:-}"
if [ -z "$DEST" ]; then
    DEST="./plex-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
fi

echo "Stopping plex.service..."
sudo systemctl stop plex.service
trap 'echo "Restarting plex.service..."; sudo systemctl start plex.service' EXIT

echo "Archiving /var/lib/plex -> $DEST ..."
sudo tar czf "$DEST" -C /var/lib plex
sudo chown "$(id -u):$(id -g)" "$DEST"

echo "Verifying archive integrity..."
tar tzf "$DEST" >/dev/null

echo ""
echo "Backup complete and verified: $DEST ($(du -h "$DEST" | cut -f1))"
echo "  Move this file to the new server, then on the vexos-nix host run:"
echo "    just enable plex && just rebuild"
echo "    just restore-plex $DEST"
