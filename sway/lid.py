#!/usr/bin/env python3
"""sway lid helper: lock on suspend, and keep every enabled screen lit except the builtin behind a shut lid."""
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

GRACE = 60  # seconds; shut shorter than this → skip the password on resume
POLL = 10  # seconds between watchdog checks
STRIKES = 2  # consecutive bad polls before acting; rides out apply transients
SETTLE = 20  # seconds of quiet required after a resume before the watchdog acts
BUILTIN = ("eDP-", "LVDS-", "DSI-")
runtime = Path(os.environ["XDG_RUNTIME_DIR"])
stamp = runtime / "lid-lock-time"
blanked = runtime / "lid-blanked"
watchlock = runtime / "lid-watch.lock"


def sway(*args):
  return subprocess.run(["swaymsg", *args], capture_output=True, text=True).stdout


def all_outputs():
  """Every output sway knows, enabled or not."""
  try:
    return json.loads(sway("-r", "-t", "get_outputs"))
  except json.JSONDecodeError:  # sway is gone
    return []


def outputs():
  """Only the outputs sway has enabled; a disabled one reports no usable power state."""
  return [o for o in all_outputs() if o.get("active")]


def is_builtin(output):
  return output["name"].startswith(BUILTIN)


def logind_flag(prop):
  # Ask logind, not sway: this has to answer from the resume hook too, where no
  # lid event ever arrives and sway only knows about switch transitions.
  out = subprocess.run(
      ["busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
       "org.freedesktop.login1.Manager", prop],
      capture_output=True, text=True).stdout
  return out.split() == ["b", "true"]


def lid_shut():
  return logind_flag("LidClosed")


def power(output, on):
  if bool(output.get("power")) != on:
    sway("output", output["name"], "power", "on" if on else "off")


def sync():
  """Light every enabled output, minus the builtin while the lid is shut over a second screen."""
  # shikane runs this after each profile switch, which is the only chance to
  # light a freshly docked screen: wlr-output-management enables an output but
  # has no notion of DPMS, so sway leaves it enabled, positioned and dark.
  if blanked.exists():
    return
  outs = outputs()
  # Ask whether another screen is *enabled*, not whether it is lit. A just-docked
  # output is enabled and still dark, so the old "lit" test made the builtin's
  # fate depend on which side of the race we sampled.
  external = any(not is_builtin(o) for o in outs)
  shut = lid_shut()
  for o in outs:
    # Power the builtin down, never disable it: a disabled output leaves the
    # layout, so yanking the dock would drop sway to zero outputs and destroy
    # every workspace. Keep the last screen lit; a shut lid is then logind's business.
    power(o, not (is_builtin(o) and shut and external))


def blank():
  """swayidle's screen blank."""
  # Name every output rather than saying "output *": sway keeps a wildcard power
  # config forever and merges it into each later hotplug, so one idle timeout
  # left every screen docked afterwards enabled but dark.
  blanked.touch()
  for o in outputs():
    power(o, False)


def wake():
  """Undo the blank, then hand the screens back to sync."""
  blanked.unlink(missing_ok=True)
  sway("output", "*", "power", "on")  # clear a wildcard an older config may have left off
  sync()


def lock():
  stamp.write_text(str(time.time()))
  subprocess.run(["swaylock", "-f"])


def maybe_unlock():
  # Resume from suspend has to un-blank too: it is a separate path from swayidle's
  # resume hook, and skipping it is what left docked screens dark after a wake.
  wake()
  if stamp.exists() and time.time() - float(stamp.read_text()) < GRACE:
      subprocess.run(["pkill", "--signal", "USR1", "-x", "swaylock"])


def shikane_state():
  """Daemon's state machine, or None if it is dead or not answering."""
  p = subprocess.run(["shikanectl", "debug", "current-state"],
                     capture_output=True, text=True)
  out = p.stdout.strip()
  return out if out and "Cannot connect" not in p.stderr else None  # exits 0 either way


def restart_shikane():
  """Restart the daemon and return the time before which nothing else should fire."""
  subprocess.run(["pkill", "-x", "shikane"])
  subprocess.Popen(["shikane"], start_new_session=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  return time.monotonic() + SETTLE


def quiescent():
  """True while screens are *meant* to be dark."""
  return blanked.exists() or lid_shut() or logind_flag("PreparingForSleep")


def watch():
  """Poll for what emits no event: a dead or wedged shikane, and a blacked-out session."""
  # shikane only compares head identity, so a clobbered layout never wakes it.
  # Geometry stays unpoliced on purpose: enforcing it would fight wdisplays.
  with open(watchlock, "w") as lock:
    try:
      fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:  # a watchdog from a previous sway reload still owns it
      return
    stuck = dark = 0
    # Re-arm after a resume: BOOTTIME advances across suspend, MONOTONIC does not.
    skew = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()
    settle = 0.0
    while True:
      time.sleep(POLL)
      now = time.monotonic()
      drift = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic() - skew
      if drift > 1:
        skew += drift
        settle = now + SETTLE
      outs = all_outputs()
      if not outs:  # sway exited; nothing left to supervise
        return
      if quiescent() or now < settle:
        stuck = dark = 0
        continue

      state = shikane_state()
      if state is None:
        settle = restart_shikane()  # back off: a daemon that refuses to start would spin
        stuck = 0
      elif state.startswith("VariantInProgress"):
        stuck += 1
        if stuck >= STRIKES:
          settle = restart_shikane()
          stuck = 0
      else:
        stuck = 0

      # Nothing enabled *and* powered means no screen to type a password into.
      if any(o.get("active") and o.get("power") for o in outs):
        dark = 0
      else:
        dark += 1
        if dark >= STRIKES:
          sway("output", "*", "enable")
          sway("output", "*", "power", "on")
          settle = restart_shikane()
          dark = 0


if __name__ == "__main__":
  {"sync": sync, "wake": wake, "blank": blank, "watch": watch,
   "lock": lock, "maybe-unlock": maybe_unlock}[sys.argv[1]]()
