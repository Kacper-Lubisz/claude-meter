#!/usr/bin/env bash
# Checks the Linux side in Docker, no Linux machine needed: builds and tests the package on
# Linux, then loads the GNOME Shell extension in a headless GNOME Shell, on demo data, and
# screenshots the top bar, the menu and each submenu in the dark and light styles.
#   scripts/check-linux.sh [out-dir]   screenshots and shell logs go to out-dir (default .build/linux-check)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "${1:-.build/linux-check}"
OUT="$(cd "${1:-.build/linux-check}" && pwd)"

echo "Building and testing on Linux..."
docker run --rm -v "$PWD":/src:ro -v "$OUT":/out -w /src swift:6.4 bash -c '
  set -e
  swift test --scratch-path /tmp/build > /tmp/test.log 2>&1 || { cat /tmp/test.log; exit 1; }
  grep "Test run" /tmp/test.log
  swift build -c release --product claude-meter --static-swift-stdlib --scratch-path /tmp/build > /dev/null
  cp /tmp/build/release/claude-meter /out/'

echo "Building the GNOME Shell image (slow the first time)..."
docker build -q -t claude-meter-gnome-check scripts/linux-check > /dev/null
for scheme in prefer-dark prefer-light; do
  echo "GNOME Shell, $scheme:"
  docker run --rm -e SCHEME=$scheme -v "$PWD/gnome":/ext:ro -v "$PWD/scripts/linux-check":/check:ro -v "$OUT":/out \
    claude-meter-gnome-check bash /check/run.sh
done
echo "Screenshots in $OUT"
