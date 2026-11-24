#!/usr/bin/env bash
# Install the bridge user services (no sudo needed):
#   quota-bridge.service  - the quota bridge itself (port 3847, Restart=always)
#   tarball-8000.service  - LAN tarball server for Chromebook flashing (:8000/ew.tgz)
# Run from anywhere:  bash bridge/scripts/install.sh
# Boot without login also needs (one-time, needs sudo):
#   sudo loginctl enable-linger "$USER"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
for u in quota-bridge.service tarball-8000.service; do
  ln -sf "$SCRIPT_DIR/$u" "$UNIT_DIR/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now quota-bridge.service tarball-8000.service
echo "active:"; systemctl --user is-active quota-bridge.service tarball-8000.service
curl -s -m 5 http://127.0.0.1:3847/health; echo
