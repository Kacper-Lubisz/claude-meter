#!/bin/bash
# Inside the GNOME Shell image: installs the extension, with the real claude-meter behind a
# stub that adds --demo, then runs session.sh in a fresh session bus.
set -u
UUID=claude-meter@kacperlubisz.com
export XDG_RUNTIME_DIR=/tmp/xdg TZ=Europe/London
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
mkdir -p ~/.local/share/gnome-shell/extensions/$UUID ~/.local/bin ~/.local/opt
cp /ext/$UUID/* ~/.local/share/gnome-shell/extensions/$UUID/
cp /out/claude-meter ~/.local/opt/claude-meter
printf '#!/bin/sh\nexec /root/.local/opt/claude-meter "$@" --demo\n' > ~/.local/bin/claude-meter
chmod +x ~/.local/bin/claude-meter ~/.local/opt/claude-meter
mkdir -p /run/dbus && dbus-daemon --system --fork 2>/dev/null
dbus-run-session -- bash /check/session.sh 2>/dev/null
status=$?
if grep -q "JS ERROR" "/out/shell-$SCHEME.log"; then
  grep -A8 "JS ERROR" "/out/shell-$SCHEME.log"
  exit 1
fi
exit $status
