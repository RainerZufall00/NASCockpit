#!/usr/bin/env python3
"""Builds index.html: large previews + home-screen size checks for every proposal."""
import os, glob, html

HERE = os.path.dirname(os.path.abspath(__file__))
INFO = {
    "A": ("Cockpit-Instrument", "Tacho-Anzeige mit Nadel, darunter zwei Server-Einheiten. Greift „Cockpit“ wörtlich auf; dunkel, technisch."),
    "B": ("Status-Ring", "Der Ring aus den Server-Karten der App um einen Server-Stapel. Am nächsten am App-Design, sehr klar auf kleinen Größen."),
    "C": ("Server-Stapel + Update", "Heller Hintergrund, blauer Stapel und oranges Update-Abzeichen – betont „alle Updates an einem Ort“."),
    "D": ("NAS-Front", "Generisches 4-Bay-Gehäuse mit Status-LEDs. Sofort als NAS erkennbar, ohne Herstellermarke."),
    "E": ("Server-Flotte", "Zentrale mit vier verbundenen Servern in den Farben der App – „alle Server in einer App“."),
    "F": ("Künstlicher Horizont", "Fluginstrument, dessen „Boden“ aus Server-Einschüben besteht. Eigenständig und mit Augenzwinkern."),
}

cards, homes_light, homes_dark = [], [], []
for path in sorted(glob.glob(os.path.join(HERE, "*.svg"))):
    key = os.path.basename(path)[0]
    title, desc = INFO[key]
    data = open(path).read()
    src = "data:image/svg+xml;utf8," + html.escape(data.replace("\n", "").replace("#", "%23"), quote=True)
    cards.append(f'''<figure class="card"><img class="icon big" src="{src}" alt="{title}">
<figcaption><b>{key} · {title}</b><span>{desc}</span>
<div class="sizes"><img class="icon s180" src="{src}" alt=""><img class="icon s60" src="{src}" alt=""><img class="icon s40" src="{src}" alt=""><img class="icon s29" src="{src}" alt=""></div>
</figcaption></figure>''')
    homes_light.append(f'<div class="app"><img class="icon s64" src="{src}" alt=""><small>{key} · NAS Cockpit</small></div>')

home = "".join(homes_light)
page = f'''<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAS Cockpit Icons</title>
<style>
:root{{--bg:#f2f2f7;--fg:#1c1c1e;--muted:#6e6e73;--card:#fff}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#000;--fg:#f2f2f7;--muted:#98989d;--card:#1c1c1e}}}}
:root[data-theme="dark"]{{--bg:#000;--fg:#f2f2f7;--muted:#98989d;--card:#1c1c1e}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}}
main{{max-width:1180px;margin:0 auto;padding:32px 16px 64px}}
h1{{font-size:30px;margin:0 0 4px}} h2{{font-size:20px;margin:40px 0 12px}} p.lead{{color:var(--muted);margin:0 0 24px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}}
.card{{margin:0;background:var(--card);border-radius:22px;padding:20px;display:flex;flex-direction:column;gap:14px}}
figcaption{{display:flex;flex-direction:column;gap:4px}} figcaption span{{color:var(--muted)}}
.icon{{border-radius:22.37%;display:block;box-shadow:0 1px 3px rgba(0,0,0,.18)}}
.big{{width:100%;max-width:300px;align-self:center}}
.sizes{{display:flex;align-items:flex-end;gap:14px;margin-top:10px}}
.s180{{width:90px}} .s60{{width:60px}} .s40{{width:40px}} .s29{{width:29px}} .s64{{width:64px}}
.home{{border-radius:28px;padding:28px 20px;display:grid;grid-template-columns:repeat(auto-fill,minmax(84px,1fr));gap:22px 10px}}
.home.light{{background:linear-gradient(160deg,#cfe3ff,#f7d9c4)}} .home.dark{{background:linear-gradient(160deg,#0b1a33,#2a1630);margin-top:12px}}
.app{{display:flex;flex-direction:column;align-items:center;gap:6px}} .app small{{font-size:11px;color:#1c1c1e;white-space:nowrap}}
.dark .app small{{color:#fff}}
</style></head><body><main>
<h1>NAS Cockpit – App-Icon-Vorschläge</h1>
<p class="lead">Sechs Richtungen, je 1024 × 1024 vollflächig (iOS setzt die abgerundete Maske selbst). Unten jeweils die Größen 180/120, 60, 40 und 29 pt zur Lesbarkeitsprüfung.</p>
<div class="grid">{"".join(cards)}</div>
<h2>Auf dem Home-Bildschirm</h2>
<div class="home light">{home}</div>
<div class="home dark">{home}</div>
</main></body></html>'''
open(os.path.join(HERE, "index.html"), "w").write(page)
print("wrote index.html")
