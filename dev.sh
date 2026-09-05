#!/bin/bash
# Sync this checkout into the Omarchy plugin directory (which hot-reloads on save).
# Usage: ./dev.sh [--enable]
set -euo pipefail
ID=$(jq -r .id manifest.json)
DEST="$HOME/.config/omarchy/plugins/$ID"
mkdir -p "$DEST"
rsync -a --delete --exclude .git --exclude dev.sh "$(dirname "$0")/" "$DEST/"
omarchy plugin validate "$DEST"
if [[ "${1:-}" == "--enable" ]]; then
  omarchy plugin enable "$ID"
fi
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
echo "synced -> $DEST"
