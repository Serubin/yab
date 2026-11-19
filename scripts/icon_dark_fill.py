"""Make an Icon Composer document's dark fill its only fill, for a dark .icns.
usage: python3 scripts/icon_dark_fill.py <document>/icon.json
"""
import json
import sys

path = sys.argv[1]
icon = json.load(open(path))
dark = [f for f in icon.get("fill-specializations", []) if f.get("appearance") == "dark"]
if dark:
    icon["fill-specializations"] = [{"value": dark[0]["value"]}]
    json.dump(icon, open(path, "w"), indent=2)
