"""Generate the Pane icon bundle: layered SVGs, Icon Composer icon.json, previews.

Coordinates are the canvas's 100-unit grid; the tile is the square (5,4)-(95,94),
so every SVG uses viewBox "5 4 90 90" and is drawn at 1024 px.
"""
import json, os, sys

OUT = sys.argv[1]

NAVY = "#0B1A45"; COBALT = "#2463EB"; DEEP = "#1645B8"; PALE = "#BFD4FF"
LIGHT = "#F3F6FE"; MIDNIGHT = "#0E1530"


def needle(cx, cy, north_len, south_len, half_w, north, south, sw):
    return (f'<g transform="rotate(40 {cx} {cy})">'
            f'<polygon points="{cx},{cy - north_len} {cx + half_w},{cy} {cx - half_w},{cy}" fill="{north}" stroke="{north}" stroke-width="{sw}" stroke-linejoin="round"/>'
            f'<polygon points="{cx},{cy + south_len} {cx + half_w},{cy} {cx - half_w},{cy}" fill="{south}" stroke="{south}" stroke-width="{sw}" stroke-linejoin="round"/>'
            f'</g>')

PEEK_BACK = f'<rect x="13" y="17" width="48" height="52" rx="16" fill="{COBALT}"/>'
PEEK_FRONT = f'<rect x="39" y="31" width="48" height="52" rx="16" fill="{PALE}"/>'
PEEK_FACE = (f'<rect x="51" y="48" width="6.5" height="16" rx="3.25" fill="{NAVY}"/>'
             + needle(72, 56, 10.5, 10.5, 3.2, NAVY, COBALT, 1.6))
SOLO_FACE = lambda pill, north, south: (
    f'<rect x="32" y="38" width="8" height="21" rx="4" fill="{pill}"/>'
    + needle(62, 48.5, 13.5, 13.5, 4, north, south, 2))

TILT = 'transform="rotate(-10 50 49)"'

# Each icon: tile fill, optional dark fill, layers listed bottom to top.
ICONS = {
    "peek": dict(title="Peek", fill=LIGHT, dark=MIDNIGHT, layers=[
        ("back", PEEK_BACK), ("front", PEEK_FRONT), ("face", PEEK_FACE)]),
    "solo": dict(title="Solo", fill=LIGHT, dark=MIDNIGHT, layers=[
        ("pane", f'<rect x="15" y="14" width="70" height="70" rx="22" fill="{COBALT}"/>'),
        ("face", SOLO_FACE("#FFFFFF", "#FFFFFF", PALE))]),
    "two-pills": dict(title="Two Pills", fill=LIGHT, dark=MIDNIGHT, layers=[
        ("back", PEEK_BACK), ("front", PEEK_FRONT),
        ("face", f'<rect x="52" y="48" width="6.5" height="16" rx="3.25" fill="{NAVY}"/>'
                 f'<rect x="67" y="48" width="6.5" height="16" rx="3.25" fill="{NAVY}"/>')]),
    "inverse": dict(title="Inverse", fill=COBALT, dark=None, layers=[
        ("pane", f'<rect x="15" y="14" width="70" height="70" rx="22" fill="{PALE}"/>'),
        ("face", SOLO_FACE(NAVY, NAVY, COBALT))]),
    "midnight": dict(title="Midnight", fill=MIDNIGHT, dark=None, layers=[
        ("back", PEEK_BACK), ("front", PEEK_FRONT), ("face", PEEK_FACE)]),
    "solo-midnight": dict(title="Solo Midnight", fill=MIDNIGHT, dark=None, layers=[
        ("pane", f'<rect x="15" y="14" width="70" height="70" rx="22" fill="{COBALT}"/>'),
        ("face", SOLO_FACE("#FFFFFF", "#FFFFFF", PALE))]),
    "stack": dict(title="Stack", fill=LIGHT, dark=MIDNIGHT, layers=[
        ("back", f'<rect x="12" y="41" width="44" height="45" rx="14" fill="{DEEP}"/>'),
        ("middle", f'<rect x="28" y="27" width="44" height="45" rx="14" fill="{COBALT}"/>'),
        ("front", f'<rect x="44" y="13" width="44" height="45" rx="14" fill="{PALE}"/>'),
        ("face", f'<rect x="56" y="28" width="5.6" height="14" rx="2.8" fill="{NAVY}"/>'
                 + needle(75, 35, 8.5, 8.5, 2.6, NAVY, COBALT, 1.4))]),
    "old-friend": dict(title="Old Friend", fill="#F5F5F1", dark="#141415", layers=[
        ("back", f'<g {TILT}><rect x="13" y="20" width="46" height="50" rx="15" fill="#0185DA"/></g>'),
        ("front", f'<g {TILT}><rect x="37" y="29" width="49" height="50" rx="15" fill="#2EBCF6"/></g>'),
        ("face", f'<g {TILT}><rect x="49" y="43" width="6.5" height="15" rx="3.25" fill="#072B43"/>'
                 '<path d="M64 52 Q69.5 45.5 77.5 44.5" fill="none" stroke="#072B43" stroke-width="5.6" stroke-linecap="round"/>'
                 '<ellipse cx="76.5" cy="64" rx="4.6" ry="3.2" fill="#0185DA"/></g>')]),
}


def svg(body, w=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{w}" viewBox="5 4 90 90">\n'
            f'  {body}\n</svg>\n')


def srgb(hexcolor):
    h = hexcolor.lstrip('#')
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


for slug, icon in ICONS.items():
    d = os.path.join(OUT, f"{slug}.icon")
    os.makedirs(os.path.join(d, "Assets"), exist_ok=True)
    for name, body in icon["layers"]:
        open(os.path.join(d, "Assets", f"{name}.svg"), "w").write(svg(body))
    fills = [{"value": {"solid": srgb(icon["fill"])}}]
    if icon["dark"]:
        fills.append({"appearance": "dark", "value": {"solid": srgb(icon["dark"])}})
    groups = [{  # Icon Composer lists groups top first, one layer per group
        "layers": [{"name": name.capitalize(), "image-name": f"{name}.svg", "glass": False}],
        "shadow": {"kind": "none", "opacity": 0.5},
        "translucency": {"enabled": False, "value": 0.5},
    } for name, _ in reversed(icon["layers"])]
    doc = {"fill-specializations": fills, "groups": groups,
           "supported-platforms": {"squares": ["macOS"]}}
    open(os.path.join(d, "icon.json"), "w").write(json.dumps(doc, indent=2) + "\n")
    # Flattened preview with the tile drawn as a macOS-style rounded square.
    tile = f'<rect x="5" y="4" width="90" height="90" rx="20.5" fill="{icon["fill"]}"/>'
    flat = tile + "\n  " + "\n  ".join(b for _, b in icon["layers"])
    os.makedirs(os.path.join(OUT, "previews"), exist_ok=True)
    open(os.path.join(OUT, "previews", f"{slug}.svg"), "w").write(svg(flat))
    if icon["dark"]:
        dtile = f'<rect x="5" y="4" width="90" height="90" rx="20.5" fill="{icon["dark"]}"/>'
        dflat = dtile + "\n  " + "\n  ".join(b for _, b in icon["layers"])
        open(os.path.join(OUT, "previews", f"{slug}-dark.svg"), "w").write(svg(dflat))

print("\n".join(ICONS))
