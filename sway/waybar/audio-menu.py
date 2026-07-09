#!/usr/bin/env python3
"""fuzzel picker for the default PipeWire sink/source (waybar mic/speaker right-click)."""
import json
import subprocess
import sys

SINK, SOURCE = "Audio/Sink", "Audio/Source"


def devices():
    data = json.loads(subprocess.check_output(["pw-dump"]))
    for obj in data:
        props = (obj.get("info") or {}).get("props") or {}
        cls = props.get("media.class")
        name = props.get("node.name", "")
        if cls not in (SINK, SOURCE) or name.endswith(".monitor"):
            continue
        yield {
            "id": obj["id"],
            "class": cls,
            "name": name,
            "desc": props.get("node.description") or props.get("node.nick") or name,
        }


def current_default(kind):
    try:
        return subprocess.check_output(["pactl", f"get-default-{kind}"], text=True).strip()
    except subprocess.CalledProcessError:
        return ""


def main():
    defaults = {SINK: current_default("sink"), SOURCE: current_default("source")}
    nodes = sorted(devices(), key=lambda n: (n["class"] != SINK, n["desc"].lower()))
    if not nodes:
        sys.exit("no audio devices found")

    by_label = {}
    for n in nodes:
        emoji = "🔊" if n["class"] == SINK else "🎤"
        mark = " ●" if n["name"] == defaults.get(n["class"]) else ""
        label = f"{emoji} {n['desc']}{mark}"
        if label in by_label:  # keep labels unique for reverse lookup
            label += f"  [{n['name']}]"
        by_label[label] = n

    picked = subprocess.run(
        ["fuzzel", "--width", "90", "--dmenu", "--prompt", "audio "],
        input="\n".join(by_label), capture_output=True, text=True,
    ).stdout.strip()

    node = by_label.get(picked)
    if node:
        subprocess.run(["wpctl", "set-default", str(node["id"])])  # reroutes following streams


if __name__ == "__main__":
    main()
