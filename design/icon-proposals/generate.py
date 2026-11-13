#!/usr/bin/env python3
"""Generates NAS Cockpit app icon proposals as 1024x1024 SVGs (full-bleed; iOS applies the mask)."""
import math, os

OUT = os.path.dirname(os.path.abspath(__file__))
S = 1024


def pt(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def arc(cx, cy, r, a0, a1):
    x0, y0 = pt(cx, cy, r, a0)
    x1, y1 = pt(cx, cy, r, a1)
    large = 1 if (a1 - a0) % 360 > 180 else 0
    return f"M{x0:.1f},{y0:.1f} A{r},{r} 0 {large} 1 {x1:.1f},{y1:.1f}"


def server_unit(x, y, w, h, fill, led, slot, rx=None, leds=2, slots=3):
    rx = rx if rx is not None else h * 0.28
    g = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"/>']
    r = h * 0.13
    cy = y + h / 2
    for i in range(leds):
        cx = x + h * 0.42 + i * r * 3.2
        g.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{led[i] if isinstance(led, list) else led}"/>')
    sw = h * 0.11
    lx0 = x + w * 0.52
    lx1 = x + w - h * 0.38
    for i in range(slots):
        sx = lx0 + i * (lx1 - lx0) / 2.4
        g.append(f'<line x1="{sx:.1f}" y1="{y + h * 0.32:.1f}" x2="{sx:.1f}" y2="{y + h * 0.68:.1f}" '
                 f'stroke="{slot}" stroke-width="{sw:.1f}" stroke-linecap="round"/>')
    return "\n".join(g)


def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">\n'
            f'<defs>{defs}</defs>\n{body}\n</svg>\n')


# ---------------------------------------------------------------- A: Cockpit-Instrument
def icon_dial():
    cx, cy, r = 512, 540, 310
    defs = '''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#172A4C"/><stop offset="1" stop-color="#070D1C"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.53" r="0.5"><stop offset="0" stop-color="#1F6BE8" stop-opacity=".45"/><stop offset="1" stop-color="#1F6BE8" stop-opacity="0"/></radialGradient>
<linearGradient id="val" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#34D3A0"/><stop offset="1" stop-color="#4D8FFF"/></linearGradient>'''
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>',
         '<rect width="1024" height="1024" fill="url(#glow)"/>',
         f'<path d="{arc(cx, cy, r, 135, 405)}" fill="none" stroke="#FFFFFF" stroke-opacity=".12" stroke-width="64" stroke-linecap="round"/>',
         f'<path d="{arc(cx, cy, r, 135, 324)}" fill="none" stroke="url(#val)" stroke-width="64" stroke-linecap="round"/>']
    for i in range(28):
        a = 135 + i * 270 / 27
        major = i % 3 == 0
        x0, y0 = pt(cx, cy, 206 if major else 222, a)
        x1, y1 = pt(cx, cy, 246, a)
        b.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" stroke="#FFFFFF" '
                 f'stroke-opacity="{.7 if major else .35}" stroke-width="{12 if major else 7}" stroke-linecap="round"/>')
    # server glyph inside lower dial
    for i in range(2):
        b.append(server_unit(407, 618 + i * 62, 210, 50, "#FFFFFF", ["#34D3A0", "#4D8FFF"] if i == 0 else ["#34D3A0", "#34D3A0"], "#0E1A33"))
    # needle
    na = 324
    tx, ty = pt(cx, cy, 232, na)
    lx, ly = pt(cx, cy, 20, na - 90)
    rx_, ry_ = pt(cx, cy, 20, na + 90)
    bx, by = pt(cx, cy, 40, na + 180)
    b.append(f'<polygon points="{tx:.1f},{ty:.1f} {lx:.1f},{ly:.1f} {bx:.1f},{by:.1f} {rx_:.1f},{ry_:.1f}" fill="#FF9F0A"/>')
    b.append(f'<circle cx="{cx}" cy="{cy}" r="42" fill="#FFFFFF"/><circle cx="{cx}" cy="{cy}" r="16" fill="#FF9F0A"/>')
    return svg("\n".join(b), defs)


# ---------------------------------------------------------------- B: Status-Ring
def icon_ring():
    defs = '''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4D8FFF"/><stop offset="1" stop-color="#1449C8"/></linearGradient>'''
    cx = cy = 512
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>',
         f'<circle cx="{cx}" cy="{cy}" r="300" fill="none" stroke="#FFFFFF" stroke-opacity=".22" stroke-width="76"/>',
         f'<path d="{arc(cx, cy, 300, -90, -90 + 0.68 * 360)}" fill="none" stroke="#FFFFFF" stroke-width="76" stroke-linecap="round"/>']
    leds = [["#34C759", "#34C759"], ["#34C759", "#FF9F0A"], ["#34C759", "#34C759"]]
    for i in range(3):
        b.append(server_unit(367, 382 + i * 92, 290, 76, "#FFFFFF", leds[i], "#1F6BE8"))
    return svg("\n".join(b), defs)


# ---------------------------------------------------------------- C: Server-Stapel + Update
def icon_stack():
    defs = '''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DCE7F8"/></linearGradient>
<linearGradient id="unit" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#3D86FF"/><stop offset="1" stop-color="#1F5BD8"/></linearGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#0B2A66" flood-opacity=".28"/></filter>'''
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>', '<g filter="url(#sh)">']
    leds = [["#5BF08A", "#5BF08A"], ["#5BF08A", "#5BF08A"], ["#5BF08A", "#FFB340"]]
    for i in range(3):
        b.append(server_unit(222, 222 + i * 186, 580, 150, "url(#unit)", leds[i], "#FFFFFF"))
    b.append('</g>')
    # update badge
    bx, by = 762, 742
    b.append(f'<circle cx="{bx}" cy="{by}" r="150" fill="#FFFFFF"/>')
    b.append(f'<circle cx="{bx}" cy="{by}" r="124" fill="#FF9F0A"/>')
    b.append(f'<path d="M{bx},{by - 66} V{by + 52} M{bx - 52},{by + 4} L{bx},{by + 56} L{bx + 52},{by + 4}" '
             f'fill="none" stroke="#FFFFFF" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>')
    return svg("\n".join(b), defs)


# ---------------------------------------------------------------- D: NAS-Front
def icon_nas():
    defs = '''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5AA2FF"/><stop offset="1" stop-color="#1F5BD8"/></linearGradient>
<linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2E333D"/><stop offset="1" stop-color="#16191F"/></linearGradient>
<linearGradient id="tray" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A404C"/><stop offset="1" stop-color="#262A33"/></linearGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="24" stdDeviation="28" flood-color="#06163A" flood-opacity=".45"/></filter>'''
    x0, y0, w, h = 222, 232, 580, 580
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>',
         f'<rect x="{x0}" y="{y0}" width="{w}" height="{h}" rx="72" fill="url(#body)" filter="url(#sh)"/>',
         f'<rect x="{x0 + 4}" y="{y0 + 4}" width="{w - 8}" height="{h - 8}" rx="68" fill="none" stroke="#FFFFFF" stroke-opacity=".08" stroke-width="4"/>']
    # status strip
    b.append(f'<circle cx="{x0 + 74}" cy="{y0 + 70}" r="20" fill="none" stroke="#4D8FFF" stroke-width="7"/>')
    b.append(f'<line x1="{x0 + 74}" y1="{y0 + 52}" x2="{x0 + 74}" y2="{y0 + 66}" stroke="#4D8FFF" stroke-width="7" stroke-linecap="round"/>')
    for i, c in enumerate(["#34C759", "#34C759", "#4D8FFF"]):
        b.append(f'<circle cx="{x0 + w - 74 - i * 42}" cy="{y0 + 70}" r="11" fill="{c}"/>')
    # trays
    pad, gap = 46, 18
    tw = (w - 2 * pad - 3 * gap) / 4
    ty0, ty1 = y0 + 130, y0 + h - 46
    for i in range(4):
        tx = x0 + pad + i * (tw + gap)
        b.append(f'<rect x="{tx:.1f}" y="{ty0}" width="{tw:.1f}" height="{ty1 - ty0}" rx="18" fill="url(#tray)"/>')
        for k in range(6):
            gy = ty0 + 110 + k * 46
            b.append(f'<line x1="{tx + 24:.1f}" y1="{gy}" x2="{tx + tw - 24:.1f}" y2="{gy}" stroke="#000000" stroke-opacity=".35" stroke-width="10" stroke-linecap="round"/>')
        led = "#FF9F0A" if i == 3 else "#34C759"
        b.append(f'<rect x="{tx + tw / 2 - 22:.1f}" y="{ty0 + 36}" width="44" height="14" rx="7" fill="{led}"/>')
    return svg("\n".join(b), defs)


# ---------------------------------------------------------------- E: Server-Flotte
def icon_fleet():
    defs = '''
<radialGradient id="bg" cx="0.5" cy="0.45" r="0.75"><stop offset="0" stop-color="#1D2C4D"/><stop offset="1" stop-color="#0A1020"/></radialGradient>
<linearGradient id="hub" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5A98FF"/><stop offset="1" stop-color="#1F5BD8"/></linearGradient>'''
    cx = cy = 512
    nodes = [(300, 300, "#2F7BFF"), (724, 300, "#FF9F0A"), (300, 724, "#34C759"), (724, 724, "#FF9F0A")]
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>']
    for x, y, _ in nodes:
        b.append(f'<line x1="{cx}" y1="{cy}" x2="{x}" y2="{y}" stroke="#FFFFFF" stroke-opacity=".28" stroke-width="16" stroke-linecap="round"/>')
    for x, y, c in nodes:
        s = 168
        b.append(f'<rect x="{x - s / 2}" y="{y - s / 2}" width="{s}" height="{s}" rx="44" fill="{c}"/>')
        for k in range(2):
            b.append(server_unit(x - 52, y - 40 + k * 46, 104, 34, "#FFFFFF", c, c, rx=10, leds=1))
    b.append(f'<circle cx="{cx}" cy="{cy}" r="128" fill="url(#hub)" stroke="#0A1020" stroke-width="20"/>')
    b.append(f'<circle cx="{cx}" cy="{cy}" r="72" fill="none" stroke="#FFFFFF" stroke-opacity=".3" stroke-width="22"/>')
    b.append(f'<path d="{arc(cx, cy, 72, -90, 160)}" fill="none" stroke="#FFFFFF" stroke-width="22" stroke-linecap="round"/>')
    return svg("\n".join(b), defs)


# ---------------------------------------------------------------- F: Künstlicher Horizont
def icon_horizon():
    defs = '''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#30353E"/><stop offset="1" stop-color="#111317"/></linearGradient>
<linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8A929F"/><stop offset="1" stop-color="#2A2E35"/></linearGradient>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1F5BD8"/><stop offset="1" stop-color="#5AA2FF"/></linearGradient>
<linearGradient id="ground" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2A3242"/><stop offset="1" stop-color="#151A24"/></linearGradient>
<clipPath id="face"><circle cx="512" cy="512" r="330"/></clipPath>'''
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>',
         '<circle cx="512" cy="512" r="384" fill="url(#bezel)"/>',
         '<circle cx="512" cy="512" r="356" fill="#0B0D10"/>',
         '<g clip-path="url(#face)"><g transform="rotate(-9 512 512)">',
         '<rect x="0" y="0" width="1024" height="540" fill="url(#sky)"/>',
         '<rect x="0" y="540" width="1024" height="484" fill="url(#ground)"/>']
    for k, wdt in enumerate([110, 190, 110]):
        y = 540 - 70 * (k + 1)
        b.append(f'<line x1="{512 - wdt / 2}" y1="{y}" x2="{512 + wdt / 2}" y2="{y}" stroke="#FFFFFF" stroke-opacity=".75" stroke-width="10" stroke-linecap="round"/>')
    for k in range(3):
        b.append(server_unit(302, 578 + k * 62, 420, 48, "#3A4558", ["#34C759", "#34C759"] if k != 1 else ["#34C759", "#FF9F0A"], "#FFFFFF", rx=14))
    b.append('<line x1="0" y1="540" x2="1024" y2="540" stroke="#FFFFFF" stroke-width="12"/>')
    b.append('</g></g>')
    # bank pointer
    b.append('<polygon points="512,168 488,214 536,214" fill="#FF9F0A"/>')
    # aircraft symbol
    b.append('<path d="M302,520 H432 L470,560 M722,520 H592 L554,560" fill="none" stroke="#FF9F0A" stroke-width="26" stroke-linecap="round" stroke-linejoin="round"/>')
    b.append('<circle cx="512" cy="520" r="22" fill="#FF9F0A"/>')
    return svg("\n".join(b), defs)


ICONS = {
    "A-cockpit-instrument": icon_dial,
    "B-status-ring": icon_ring,
    "C-server-stapel": icon_stack,
    "D-nas-front": icon_nas,
    "E-server-flotte": icon_fleet,
    "F-kuenstlicher-horizont": icon_horizon,
}

# ---------------------------------------------------------------- Final: C ausgearbeitet (light / dark / tinted)
FINAL = {
    "light": dict(bg=("#FFFFFF", "#DCE7F8"), unit=("#3D86FF", "#1F5BD8"), hi="#FFFFFF", hi_op=".22",
                  led="#5BF08A", warn="#FFB340", slot="#FFFFFF", badge=("#FFB340", "#FF8A00"), arrow="#FFFFFF",
                  shadow=("#0B2A66", ".26")),
    "dark": dict(bg=("#1B2744", "#080D1A"), unit=("#5A98FF", "#2563EB"), hi="#FFFFFF", hi_op=".25",
                 led="#5BF08A", warn="#FFB340", slot="#FFFFFF", badge=("#FFB340", "#FF8A00"), arrow="#FFFFFF",
                 shadow=("#000000", ".55")),
    # Tinted: grayscale on black, the system maps luminance to the user's tint.
    "tinted": dict(bg=("#000000", "#000000"), unit=("#9C9C9C", "#6A6A6A"), hi="#FFFFFF", hi_op=".18",
                   led="#FFFFFF", warn="#FFFFFF", slot="#1E1E1E", badge=("#FFFFFF", "#E6E6E6"), arrow="#000000",
                   shadow=("#000000", "0")),
}


def icon_final(v):
    c = FINAL[v]
    bx, by, br, gap = 740, 730, 128, 28          # update badge + transparent ring around it
    x, w, h, pitch, y0 = 156, 580, 150, 184, 166  # server units
    defs = f'''
<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1024"><stop offset="0" stop-color="{c['bg'][0]}"/><stop offset="1" stop-color="{c['bg'][1]}"/></linearGradient>
<linearGradient id="unit" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="{c['unit'][0]}"/><stop offset="1" stop-color="{c['unit'][1]}"/></linearGradient>
<linearGradient id="badge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['badge'][0]}"/><stop offset="1" stop-color="{c['badge'][1]}"/></linearGradient>
<filter id="sh" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="{c['shadow'][0]}" flood-opacity="{c['shadow'][1]}"/></filter>'''
    b = ['<rect width="1024" height="1024" fill="url(#bg)"/>', '<g filter="url(#sh)">']
    for i in range(3):
        y = y0 + i * pitch
        last = i == 2
        b.append(server_unit(x, y, w, h, "url(#unit)", [c['led'], c['warn'] if last else c['led']], c['slot'],
                             slots=2 if last else 3))
        b.append(f'<path d="M{x + 42},{y + 3} H{x + w - 42}" stroke="{c["hi"]}" stroke-opacity="{c["hi_op"]}" '
                 f'stroke-width="5" stroke-linecap="round"/>')
    b.append('</g>')
    # cut-out ring: background-coloured disc (bg gradient is in user space, so it matches seamlessly)
    b.append(f'<circle cx="{bx}" cy="{by}" r="{br + gap}" fill="url(#bg)"/>')
    b.append(f'<g filter="url(#sh)"><circle cx="{bx}" cy="{by}" r="{br}" fill="url(#badge)"/></g>')
    b.append(f'<path d="M{bx},{by - 62} V{by + 50} M{bx - 50},{by + 2} L{bx},{by + 52} L{bx + 50},{by + 2}" '
             f'fill="none" stroke="{c["arrow"]}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>')
    return svg("\n".join(b), defs)


if __name__ == "__main__":
    for name, fn in ICONS.items():
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(fn())
        print("wrote", name)
    os.makedirs(os.path.join(OUT, "final"), exist_ok=True)
    for v in FINAL:
        with open(os.path.join(OUT, "final", f"AppIcon-{v}.svg"), "w") as f:
            f.write(icon_final(v))
        print("wrote final", v)
