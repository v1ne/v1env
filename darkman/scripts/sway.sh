#!/bin/sh
# Set Sway's window colours (Kimbie) for the given mode. Invoked by
# darkman (light/dark) or sway (no arg)

if [ -z "$SWAYSOCK" ]; then
  SWAYSOCK=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/sway-ipc.*.sock 2>/dev/null | head -n1)
  export SWAYSOCK
fi

# Color columns: border background text indicator child_border
(
case "${1:-$(darkman get 2>/dev/null)}" in
  light)
    swaymsg "client.focused          #5d90cd #5d90cd #fbebd4 #5d90cd #5d90cd"
    swaymsg "client.focused_inactive #eeddc0 #eeddc0 #4a3631 #eeddc0 #eeddc0"
    swaymsg "client.unfocused        #fbebd4 #fbebd4 #6e5346 #d0b48f #d0b48f"
    swaymsg "client.urgent           #d43552 #d43552 #fbebd4 #d43552 #d43552"
    swaymsg "client.background        #fbebd4"
    ;;
  *)
    swaymsg "client.focused          #5d90cd #5d90cd #f2cca8 #5d90cd #5d90cd"
    swaymsg "client.focused_inactive #2b2113 #2b2113 #a58b6a #2b2113 #2b2113"
    swaymsg "client.unfocused        #221a0f #221a0f #7d6f48 #2b2113 #2b2113"
    swaymsg "client.urgent           #c87e5a #c87e5a #221a0f #c87e5a #c87e5a"
    swaymsg "client.background        #221a0f"
    ;;
esac
) 2>/dev/null
