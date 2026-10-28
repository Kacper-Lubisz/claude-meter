#!/usr/bin/env bash
# Builds the claude-meter command and installs it with the GNOME Shell extension that puts it
# in the top bar.
#   scripts/install-linux.sh            build + install
#   scripts/install-linux.sh uninstall  remove both (keeps config and history)
set -euo pipefail
cd "$(dirname "$0")/.."

UUID="claude-meter@kacperlubisz.com"
BIN="$HOME/.local/bin/claude-meter"
EXT="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"

if [[ "${1:-}" == "uninstall" ]]; then
  gnome-extensions disable "$UUID" 2>/dev/null || true
  rm -rf "$EXT" "$BIN"
  echo "Removed. Config remains at ~/.config/claude-meter, history at ~/.local/share/claude-meter."
  exit 0
fi

echo "Building..."
# Static so the binary doesn't depend on where the Swift toolchain is installed.
swift build -c release --product claude-meter --static-swift-stdlib
install -D -m 755 "$(swift build -c release --show-bin-path)/claude-meter" "$BIN"
echo "Installed $BIN"

rm -rf "$EXT"
mkdir -p "$EXT"
cp gnome/"$UUID"/* "$EXT"/
echo "Installed the GNOME Shell extension to $EXT"

# A running GNOME Shell only picks up new extensions when it starts.
if gnome-extensions enable "$UUID" 2>/dev/null; then
  echo "Enabled. If it isn't in the top bar, log out and back in."
else
  echo "Log out and back in, then run: gnome-extensions enable $UUID"
fi
"$BIN" status | head -1
