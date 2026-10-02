#!/usr/bin/env bash
# Fork install: build the release binary from this checkout and make it the
# Zeron this user runs. It lands in ~/.zeron/fork, outside the self-updating
# ~/.zeron/app layout, so the in-app updater only reports new releases and
# never swaps the fork out. The ~/.local/bin link, the launcher entry, and the
# engine's systemd unit are pointed at it, then the engine is restarted.
#
# Usage: scripts/install-fork.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
DEST="$HOME/.zeron/fork"
DESKTOP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/zeron.desktop"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/zeron.service"

cd "$ROOT"
BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "main" ]; then
  echo "Refusing to install from '${BRANCH:-detached HEAD}': switch to main first." >&2
  exit 1
fi
cargo build --release --locked -p zeron

mkdir -p "$DEST" "$HOME/.local/bin"
install -m 755 target/release/zeron "$DEST/zeron"
install -m 644 dist/zeron.png "$DEST/zeron.png"
ln -sfn "$DEST/zeron" "$HOME/.local/bin/zeron"

if [ -f "$DESKTOP" ]; then
  sed -i "s|$HOME/.zeron/app/current/|$DEST/|g" "$DESKTOP"
fi
if [ -f "$UNIT" ]; then
  sed -i 's|%h/.zeron/app/current/zeron|%h/.zeron/fork/zeron|' "$UNIT"
  systemctl --user daemon-reload
  systemctl --user restart zeron.service
fi

echo "Installed $("$DEST/zeron" --version) from $(git rev-parse --short HEAD) into $DEST."
echo "Engine restarted. Close and reopen the Zeron window to finish."
