#!/usr/bin/env python3
"""swayidle lid helper: lock on suspend, auto-unlock if the lid was shut only briefly."""
import os
import subprocess
import sys
import time
from pathlib import Path

GRACE = 60  # seconds; shut shorter than this → skip the password on resume
stamp = Path(os.environ["XDG_RUNTIME_DIR"]) / "lid-lock-time"


def lock():
  stamp.write_text(str(time.time()))
  subprocess.run(["swaylock", "-f"])


def maybe_unlock():
  if stamp.exists() and time.time() - float(stamp.read_text()) < GRACE:
      subprocess.run(["pkill", "--signal", "USR1", "-x", "swaylock"])


if __name__ == "__main__":
  {"lock": lock, "maybe-unlock": maybe_unlock}[sys.argv[1]]()
