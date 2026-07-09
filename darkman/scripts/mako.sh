#!/bin/sh
# darkman hook: flip mako's colour mode. Layout stays in the config; only the
# [mode=dark]/[mode=light] colour blocks switch.
case "$1" in
  dark|light) makoctl mode -s "$1" 2>/dev/null ;;
  *) exit 1 ;;
esac
