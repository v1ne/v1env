#!/bin/sh
# The names for the Arc theme variations are ambiguous:
# "Darker" is actually LESS DARK than "Dark".
case "$1" in
  dark)
    THEME=Yaru-dark
    COLORS=prefer-dark
  ;;
  light)
    THEME=Yaru
    COLORS=default
  ;;
  default) exit 1 ;;
esac
gsettings set org.gnome.desktop.interface gtk-theme "$THEME"
gsettings set org.gnome.desktop.interface icon-theme "$THEME"
gsettings set org.gnome.desktop.interface color-scheme "$COLORS"


