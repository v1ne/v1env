#!/bin/sh
case "$1" in
  dark)  src="themes/dark.toml"  ;;
  light) src="themes/light.toml" ;;
  *) exit 1 ;;
esac

cd $HOME/.config/alacritty || exit 1
ln -sf $src theme.toml || exit 1
alacritty msg config "import=['~/.config/alacritty/theme.toml']"
