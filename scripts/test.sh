#!/usr/bin/env bash
# Runs the MeterCore tests. With only the Command Line Tools installed, the default
# swiftbuild backend doesn't find the Swift Testing macro plugin, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
