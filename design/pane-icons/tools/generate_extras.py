"""Pane Dev (blueprint) icon and the standalone welcome figure.

Same 100-unit grid as generate.py. Run from the repo root:
    python3 -I design/pane-icons/tools/generate_extras.py design/pane-icons
then render PNGs with tools/render.js.
"""
import json, os, sys

OUT = sys.argv[1]
NAVY = "#0B1A45"; COBALT = "#2463EB"; PALE = "#BFD4FF"; PRINT = "#1F5FD6"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def needle_shapes(cx, cy, length, half_w, north, south, sw, south_stroke=None):
    s = south_stroke or south
    return (f'<g transform="rotate(40 {cx} {cy})">'
            f'<polygon points="{cx},{cy - length} {cx + half_w},{cy} {cx - half_w},{cy}" fill="{north}" stroke="{north}" stroke-width="{sw}" stroke-linejoin="round"/>'
            f'<polygon points="{cx},{cy + length} {cx + half_w},{cy} {cx - half_w},{cy}" fill="{south}" stroke="{s}" stroke-width="{sw}" stroke-linejoin="round"/>'
            f'</g>')


# ---------------------------------------------------------------- Pane Dev
def blueprint():
    W = "#FFFFFF"
    parts = []
    # Grid: minor every 2.5 units, major every 10, across the tile square.
    x = 5.0
    while x <= 95.01:
        major = abs((x - 5) % 10) < 0.01
        op = 0.22 if major else 0.1
        parts.append(f'<line x1="{x:.2f}" y1="4" x2="{x:.2f}" y2="94" stroke="{W}" stroke-opacity="{op}" stroke-width="0.25"/>')
        x += 2.5
    y = 4.0
    while y <= 94.01:
        major = abs((y - 4) % 10) < 0.01
        op = 0.22 if major else 0.1
        parts.append(f'<line x1="5" y1="{y:.2f}" x2="95" y2="{y:.2f}" stroke="{W}" stroke-opacity="{op}" stroke-width="0.25"/>')
        y += 2.5
    dash = 'stroke-dasharray="1.2 1"'
    # Construction lines through the front pane's middle and along the needle.
    parts += [
        f'<line x1="30" y1="57" x2="94" y2="57" stroke="{W}" stroke-opacity="0.55" stroke-width="0.3" {dash}/>',
        f'<line x1="63" y1="22" x2="63" y2="92" stroke="{W}" stroke-opacity="0.55" stroke-width="0.3" {dash}/>',
        f'<line x1="56.6" y1="83.3" x2="91.3" y2="28.1" stroke="{W}" stroke-opacity="0.45" stroke-width="0.3" {dash}/>',
        f'<line x1="37" y1="43" x2="89" y2="95" stroke="{W}" stroke-opacity="0.3" stroke-width="0.3" {dash}/>',
    ]
    # Panes: outlines, with dashed inner offsets.
    for (x0, y0) in ((13, 17), (39, 31)):
        parts.append(f'<rect x="{x0}" y="{y0}" width="48" height="52" rx="16" fill="none" stroke="{W}" stroke-width="1.1"/>')
        parts.append(f'<rect x="{x0 + 2.5}" y="{y0 + 2.5}" width="43" height="47" rx="13.5" fill="none" stroke="{W}" stroke-opacity="0.55" stroke-width="0.35" {dash}/>')
    # Face: the pill solid, the needle's north half solid and south half drawn.
    parts.append(f'<rect x="51" y="48" width="6.5" height="16" rx="3.25" fill="{W}"/>')
    parts.append(f'<circle cx="54.25" cy="51.25" r="4.6" fill="none" stroke="{W}" stroke-opacity="0.5" stroke-width="0.3" {dash}/>')
    parts.append(f'<circle cx="54.25" cy="60.75" r="4.6" fill="none" stroke="{W}" stroke-opacity="0.5" stroke-width="0.3" {dash}/>')
    parts.append(needle_shapes(72, 56, 10.5, 3.2, W, "none", 0.8, south_stroke=W))
    parts.append(f'<circle cx="72" cy="56" r="1.2" fill="none" stroke="{W}" stroke-width="0.35"/>')
    # Dimensions: overall width along the top, height down the left, the needle's angle.
    font = 'font-family="SF Mono, Menlo, monospace" font-size="3.4" fill="#FFFFFF"'
    parts += [
        f'<line x1="13" y1="10" x2="87" y2="10" stroke="{W}" stroke-width="0.35"/>',
        f'<polygon points="13,10 15.6,9 15.6,11" fill="{W}"/>',
        f'<polygon points="87,10 84.4,9 84.4,11" fill="{W}"/>',
        f'<line x1="13" y1="8" x2="13" y2="16" stroke="{W}" stroke-opacity="0.6" stroke-width="0.3"/>',
        f'<line x1="87" y1="8" x2="87" y2="30" stroke="{W}" stroke-opacity="0.6" stroke-width="0.3"/>',
        f'<rect x="44" y="7.6" width="12" height="4.8" fill="{PRINT}"/>',
        f'<text x="50" y="11.2" text-anchor="middle" {font}>1024</text>',
        f'<line x1="8.5" y1="17" x2="8.5" y2="83" stroke="{W}" stroke-width="0.35"/>',
        f'<polygon points="8.5,17 7.5,19.6 9.5,19.6" fill="{W}"/>',
        f'<polygon points="8.5,83 7.5,80.4 9.5,80.4" fill="{W}"/>',
        f'<rect x="6.1" y="44" width="4.8" height="12" fill="{PRINT}"/>',
        f'<text x="8.5" y="50" text-anchor="middle" transform="rotate(-90 8.5 50)" dy="1.2" {font}>768</text>',
        f'<path d="M72 42 A14 14 0 0 1 81 45.3" fill="none" stroke="{W}" stroke-width="0.35"/>',
        f'<text x="73.5" y="39.6" {font}>40°</text>',
    ]
    return "\n  ".join(parts)


bp = blueprint()
dev = os.path.join(OUT, "pane-dev.icon")
write(os.path.join(dev, "Assets", "blueprint.svg"),
      f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="5 4 90 90">\n  {bp}\n</svg>\n')
r, g, b = (int(PRINT[i:i + 2], 16) / 255 for i in (1, 3, 5))
fill = f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"
write(os.path.join(dev, "icon.json"), json.dumps({
    "fill-specializations": [{"value": {"solid": fill}}, {"appearance": "dark", "value": {"solid": fill}}],
    "groups": [{"layers": [{"name": "Blueprint", "image-name": "blueprint.png", "glass": False}],
                "shadow": {"kind": "none", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5}}],
    "supported-platforms": {"squares": ["macOS"]},
}, indent=2) + "\n")
write(os.path.join(OUT, "previews", "pane-dev.svg"),
      f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="5 4 90 90">\n'
      f'  <rect x="5" y="4" width="90" height="90" rx="20.5" fill="{PRINT}"/>\n'
      f'  <clipPath id="t"><rect x="5" y="4" width="90" height="90" rx="20.5"/></clipPath>\n'
      f'  <g clip-path="url(#t)">{bp}</g>\n</svg>\n')

# ---------------------------------------------------------------- the figure
# Square canvas around the mark (panes span 13..87 x 17..83), room for shadow.
# Each pane is drawn as a thick slab of glass, the way Yab's mark is: a body
# that is light in the middle and saturated where the glass is thickest, a
# dark inner edge, a bright rim lit from the top left, an inner lip, a long
# specular streak and a caustic glow pooled along the bottom edge.
VB = 'viewBox="6 5 88 88"'


def slab(key, x, y, w, h, r, light, light_a, mid, mid_a, deep, highlights):
    clip = f'clip-{key}'
    shape = f'x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}"'
    defs = f'''
    <clipPath id="{clip}"><rect {shape}/></clipPath>
    <radialGradient id="{key}-body" cx="0.46" cy="0.42" r="0.72"><stop offset="0" stop-color="{light}" stop-opacity="{light_a}"/><stop offset="0.6" stop-color="{mid}" stop-opacity="{mid_a}"/><stop offset="1" stop-color="{deep}" stop-opacity="0.92"/></radialGradient>
    <mask id="{key}-out" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100"><rect x="0" y="0" width="100" height="100" fill="#FFFFFF"/><rect {shape} fill="#000000"/></mask>
    <linearGradient id="{key}-rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.2"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.6"/></linearGradient>
    <linearGradient id="{key}-streak" gradientUnits="userSpaceOnUse" x1="{x}" y1="{y + h * 0.55}" x2="{x + w * 0.6}" y2="{y}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="0.45" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
    <linearGradient id="{key}-gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.8"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.08"/></linearGradient>
    <linearGradient id="{key}-glint" gradientUnits="userSpaceOnUse" x1="{x + w}" y1="{y + h * 0.5}" x2="{x + w * 0.45}" y2="{y + h}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
    <linearGradient id="{key}-fresnel" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#DDF0FF" stop-opacity="0.9"/><stop offset="0.5" stop-color="#7FC0FF" stop-opacity="0.3"/><stop offset="1" stop-color="#BFE4FF" stop-opacity="0.85"/></linearGradient>
    <linearGradient id="{key}-window" gradientUnits="userSpaceOnUse" x1="{x}" y1="{y + h * 0.7}" x2="{x + w * 0.75}" y2="{y}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.85"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
    <linearGradient id="{key}-edge" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{deep}" stop-opacity="0.35"/><stop offset="1" stop-color="{deep}" stop-opacity="0.95"/></linearGradient>'''
    body = f'''<g mask="url(#{key}-out)"><rect x="{x}" y="{y + 1.8}" width="{w}" height="{h}" rx="{r}" fill="{deep}" opacity="0.22" filter="url(#shade)"/></g>
  <rect {shape} fill="url(#{key}-body)"/>
  <g clip-path="url(#{clip})">
    <rect {shape} fill="none" stroke="url(#{key}-edge)" stroke-width="16" opacity="0.65" filter="url(#turn)"/>
    <rect {shape} fill="none" stroke="url(#{key}-fresnel)" stroke-width="2.4" filter="url(#rimsoft)"/>
    <rect x="{x + 6}" y="{y + 6}" width="{w - 12}" height="{h - 12}" rx="{r - 6}" fill="none" stroke="#DCE9FF" stroke-opacity="0.35" stroke-width="1.6" filter="url(#wall)"/>
    <ellipse cx="{x + w * 0.52}" cy="{y + h * 0.6}" rx="{w * 0.34}" ry="{h * 0.3}" fill="#BFF0FF" opacity="0.28" filter="url(#core)"/>
{highlights}
    <ellipse cx="{x + w * 0.42}" cy="{y - h * 0.18}" rx="{w * 0.78}" ry="{h * 0.6}" fill="url(#{key}-gloss)" opacity="0.45" filter="url(#wall)"/>
  </g>'''
    return defs, body


def glint(cx, cy, rx, ry, a=1.0):
    return f'    <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="#FFFFFF" opacity="{a}" filter="url(#crisp)"/>'


def soft(cx, cy, rx, ry, a):
    return f'    <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="#FFFFFF" opacity="{a}" filter="url(#fold)"/>'


def window(key, d):
    return f'    <path d="{d}" fill="none" stroke="url(#{key}-window)" stroke-width="2.6" stroke-linecap="round" filter="url(#fold)"/>'


# Back pane (13,17 48x52 r16): a short reflection hugging only the top edge,
# a broad soft hot spot, two small glints.
BACK_LIGHT = "\n".join([
    window("back", "M20 21.2 Q24 20.2 30 20.2 H44"),
    soft(22.5, 25.5, 5.2, 3.2, 0.45),
    glint(31.5, 19.4, 1.8, 0.4, 0.9),
    glint(14.6, 52, 0.4, 1.8, 0.65),
    '    <ellipse cx="28" cy="63.5" rx="15" ry="4.5" fill="#DCE8FF" opacity="0.4" filter="url(#glow)"/>',
])
# Front pane (39,31 48x52 r16): the long curved window reflection, a tight
# hot spot, glints of differing length at the top, right and bottom left.
FRONT_LIGHT = "\n".join([
    window("front", "M43 63 V47 A12 12 0 0 1 55 35 H72"),
    soft(49.5, 40.5, 3.6, 2.4, 0.6),
    glint(48.5, 40, 1.5, 0.9, 1),
    glint(68, 33.2, 3.2, 0.45, 0.95),
    glint(85, 66, 0.45, 2.8, 0.8),
    glint(53, 81, 4, 0.45, 0.7),
    glint(80.5, 36.5, 0.5, 0.5, 0.9),
    '    <ellipse cx="68" cy="77" rx="18" ry="5.5" fill="#DCE8FF" opacity="0.5" filter="url(#glow)"/>',
])

back_defs, BACK = slab("back", 13, 17, 48, 52, 16, "#4FA2FF", 0.92, "#1C6CFF", 0.97, "#0A3FD0", BACK_LIGHT)
front_defs, FRONT_GLASS = slab("front", 39, 31, 48, 52, 16, "#7CC6FF", 0.82, "#2E86FF", 0.9, "#0B4FE0", FRONT_LIGHT)
DEFS = f'''<defs>{back_defs}{front_defs}
    <filter id="shade" x="-30%" y="-30%" width="160%" height="170%"><feGaussianBlur stdDeviation="2"/></filter>
    <filter id="drop" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="2" stdDeviation="2.2" flood-color="#0F2F98" flood-opacity="0.24"/></filter>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="1.1"/></filter>
    <filter id="core" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
    <filter id="turn" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="3"/></filter>
    <filter id="fold" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.9"/></filter>
    <filter id="wall" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="1.6"/></filter>
    <filter id="rimsoft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.55"/></filter>
    <filter id="crisp" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.18"/></filter>
    <filter id="streak" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.45"/></filter>
    <filter id="hair" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="0.25"/></filter>
    <filter id="glow" x="-50%" y="-100%" width="200%" height="300%"><feGaussianBlur stdDeviation="1.6"/></filter>
    <filter id="ink" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="0.4" stdDeviation="0.4" flood-color="#FFFFFF" flood-opacity="0.45"/></filter>
  </defs>'''
FACE = (f'<g filter="url(#ink)"><rect x="51" y="48" width="6.5" height="16" rx="3.25" fill="{NAVY}"/>'
        + needle_shapes(72, 56, 10.5, 3.2, NAVY, COBALT, 1.6) + '</g>')
FRONT = FRONT_GLASS + FACE
FLAT = (f'<rect x="13" y="17" width="48" height="52" rx="16" fill="{COBALT}"/>'
        f'<rect x="39" y="31" width="48" height="52" rx="16" fill="{PALE}"/>'
        f'<rect x="51" y="48" width="6.5" height="16" rx="3.25" fill="{NAVY}"/>'
        + needle_shapes(72, 56, 10.5, 3.2, NAVY, COBALT, 1.6))

fig = os.path.join(OUT, "figure")
svg = lambda body: f'<svg xmlns="http://www.w3.org/2000/svg" width="1254" height="1254" {VB}>\n  {DEFS}\n  {body}\n</svg>\n'
write(os.path.join(fig, "pane-mark.svg"), svg(BACK + FRONT))
write(os.path.join(fig, "pane-mark-back.svg"), svg(BACK))
write(os.path.join(fig, "pane-mark-front.svg"), svg(FRONT))
write(os.path.join(fig, "pane-mark-flat.svg"), svg(FLAT))
print("pane-dev.icon, previews/pane-dev.svg, figure/*.svg")
