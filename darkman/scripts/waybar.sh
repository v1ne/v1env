#!/bin/sh
# darkman hook: swap waybar's stylesheet symlink, then SIGUSR2 to reload it.
case "$1" in
  dark)  src="style-dark.css"  ;;
  light) src="style-light.css" ;;
  *) exit 1 ;;
esac

cd "$HOME/.config/waybar" || exit 1
ln -sf "$src" style.css || exit 1
killall -SIGUSR2 waybar 2>/dev/null || true
