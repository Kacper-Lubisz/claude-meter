# GNOME Shell for loading the extension headless. Built and run by scripts/check-linux.sh.
FROM ubuntu:26.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      gnome-shell gnome-shell-extension-prefs dbus-daemon dbus-x11 libgl1-mesa-dri mesa-utils xwayland \
      libcurl4t64 fonts-cantarell adwaita-icon-theme gsettings-desktop-schemas >/dev/null
# There's no systemd in a container. With logind not activatable, the shell treats it as absent
# instead of failing to start.
RUN rm -f /usr/share/dbus-1/system-services/org.freedesktop.login1.service
