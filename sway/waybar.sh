#!/bin/sh
# Racing sway's own dbus-update-activation-environment costs waybar a ~25s portal timeout.
dbus-update-activation-environment --systemd WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway
exec waybar
