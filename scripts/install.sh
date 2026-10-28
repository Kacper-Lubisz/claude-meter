#!/usr/bin/env bash
# Builds Claude Meter.app, installs it to ~/Applications, and starts it at login.
#   scripts/install.sh            build + install + (re)start
#   scripts/install.sh uninstall  stop and remove everything except config/history
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.kacper.claude-meter"
APP="$HOME/Applications/Claude Meter.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -rf "$APP" "$AGENT"
  echo "Removed. Config remains at ~/.config/claude-meter, history at ~/Library/Application Support/ClaudeMeter."
  exit 0
fi

VERSION="$(sed -n 's/^ *public static let current = "\(.*\)"$/\1/p' Sources/MeterCore/Version.swift)"

echo "Building $VERSION..."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeMeter"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMeter"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Claude Meter</string>
  <key>CFBundleExecutable</key><string>ClaudeMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

echo "Installing LaunchAgent"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeMeter</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ClaudeMeter.log</string>
</dict></plist>
PLIST

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrapping too early fails with error 5.
for _ in $(seq 1 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; /bin/sleep 0.1; done
launchctl bootstrap "$DOMAIN" "$AGENT"
echo "Running. It's in your menu bar and will start at login."
