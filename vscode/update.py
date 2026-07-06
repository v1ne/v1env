#!/usr/bin/env python3
"""Merge vscode/user-settings.json + $LOCAL_VSCODE_USERJSON → VS Code settings file."""

import json
import os
import pathlib
import re
import sys


def load_jsonc(path):
    text = pathlib.Path(path).read_text()
    text = re.sub(r'//[^\n]*', '', text)        # strip // comments
    text = re.sub(r',(\s*[}\]])', r'\1', text)  # strip trailing commas
    return json.loads(text)


def deep_merge(base, override):
    out = base.copy()
    for k, v in override.items():
        out[k] = deep_merge(base[k], v) if isinstance(v, dict) and k in base else v
    return out


cwd_base = pathlib.Path.cwd() / "user-settings.json"
script_base = pathlib.Path(__file__).parent / "user-settings.json"
if cwd_base.exists():
    base_path = cwd_base
elif script_base.exists():
    base_path = script_base
else:
    sys.exit(f"user-settings.json not found in {pathlib.Path.cwd()} or {pathlib.Path(__file__).parent}")
local_path = os.environ.get("LOCAL_VSCODE_USERJSON")
out_path = pathlib.Path.home() / ".config/Code/User/settings.json"

if not local_path:
    sys.exit("LOCAL_VSCODE_USERJSON is not set")

merged = deep_merge(load_jsonc(base_path), load_jsonc(local_path))
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(merged, indent=4, sort_keys=True) + "\n")
print(f"Wrote {out_path}")
