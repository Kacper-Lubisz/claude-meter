#!/bin/bash
# Starts GNOME Shell headless with the extension enabled, then screenshots the top bar, the
# open menu and each submenu. --unsafe-mode lets Eval and Screenshot be called over D-Bus.
UUID=claude-meter@kacperlubisz.com
gsettings set org.gnome.shell enabled-extensions "['$UUID']"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.desktop.interface color-scheme "$SCHEME"
gnome-shell --headless --wayland --no-x11 --unsafe-mode --virtual-monitor 1600x1000 > "/out/shell-$SCHEME.log" 2>&1 &
sleep 25

state=$(gnome-extensions info $UUID | grep State)
echo "  extension $state"
[[ "$state" == *ACTIVE* ]] || exit 1

shot() { gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Screenshot \
  --method org.gnome.Shell.Screenshot.Screenshot false false "/out/$1-$SCHEME.png" >/dev/null; }
ev() { gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
  --method org.gnome.Shell.Eval "$1" >/dev/null; }
MENU="Main.panel.statusArea['$UUID'].menu"
SUBS="$MENU._getMenuItems().filter(i => i.menu && i.menu !== $MENU)"

shot panel
ev "$MENU.open()"
sleep 2
shot menu
for n in 0 1 2; do
  ev "$SUBS.forEach(s => s.setSubmenuShown(false))"
  sleep 1
  ev "$SUBS[$n].setSubmenuShown(true)"
  sleep 2
  shot "submenu$n"
done

# The 30-second refresh mustn't fold up a submenu that's open.
sleep 35
still=$(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
  --method org.gnome.Shell.Eval "$SUBS[2].menu.isOpen")
echo "  submenu still open after a refresh: $still"
[[ "$still" == *"'true'"* ]]
