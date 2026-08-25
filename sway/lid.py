#!/usr/bin/env python3
"""sway lid helper: lock on suspend, and light the builtin panel only when it is the screen to use."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

GRACE = 60  # seconds; shut shorter than this → skip the password on resume
BUILTIN = ("eDP-", "LVDS-", "DSI-")
stamp = Path(os.environ["XDG_RUNTIME_DIR"]) / "lid-lock-time"


def sway(*args):
  return subprocess.run(["swaymsg", *args], capture_output=True, text=True).stdout


def outputs():
  return json.loads(sway("-r", "-t", "get_outputs"))


def is_builtin(output):
  return output["name"].startswith(BUILTIN)


def lid_shut():
  # Ask logind, not sway: this has to answer from the resume hook too, where no
  # lid event ever arrives and sway only knows about switch transitions.
  out = subprocess.run(
      ["busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
       "org.freedesktop.login1.Manager", "LidClosed"],
      capture_output=True, text=True).stdout
  return out.split() == ["b", "true"]


def sync():
  """Darken the builtin panel exactly while the lid is shut and some other screen is lit."""
  outs = outputs()
  lit_elsewhere = any(not is_builtin(o) and o.get("dpms") for o in outs)
  # Power it down, never disable it: a disabled output leaves the layout, so
  # yanking the dock would drop sway to zero outputs and destroy every
  # workspace. Keep the last screen lit; a shut lid is then logind's business.
  on = not (lid_shut() and lit_elsewhere)
  for o in outs:
    if is_builtin(o) and bool(o.get("dpms")) != on:
      sway("output", o["name"], "power", "on" if on else "off")


def wake():
  """Undo swayidle's blanking, then hand the builtin panel back to sync."""
  sway("output", "*", "power", "on")
  sync()


def lock():
  stamp.write_text(str(time.time()))
  subprocess.run(["swaylock", "-f"])


def maybe_unlock():
  sync()
  if stamp.exists() and time.time() - float(stamp.read_text()) < GRACE:
      subprocess.run(["pkill", "--signal", "USR1", "-x", "swaylock"])


if __name__ == "__main__":
  {"sync": sync, "wake": wake, "lock": lock, "maybe-unlock": maybe_unlock}[sys.argv[1]]()
