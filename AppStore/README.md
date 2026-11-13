# App-Store-Release von NAS Cockpit

Alles für den Eintrag in App Store Connect. Die Texte liegen im Layout von `fastlane deliver` und lassen sich so
auch automatisch hochladen. Von Hand kopieren geht genauso gut.

```
AppStore/
  metadata/
    en-US/                Hauptsprache: Name, Untertitel, Beschreibung, Keywords, Werbetext, Neuerungen, URLs
    de-DE/                Deutsch (die App-Oberfläche ist Englisch, das steht in der Beschreibung)
    review_information/   Kontakt und Hinweise für das App-Review (Telefonnummer noch eintragen)
    copyright.txt, primary_category.txt, secondary_category.txt
  Screenshots/            nicht im Repo (gut 80 MB), mit den Tools neu erzeugen
    en-US/, de-DE/        je Sprache, gleiche Aufnahmen, eigene Überschriften:
      iPhone-6.9/         8 Bilder, 1320 × 2868
      iPhone-6.3/         8 Bilder, 1206 × 2622 – für das Feld „6,1″/6,3″“
      iPad-13/            5 Bilder, 2752 × 2064 – Querformat, alle drei Spalten sichtbar
      iPhone-Duo-outer/   5 Bilder, 1398 × 2034 – zugeklappt
      iPhone-Duo-inner/   5 Bilder, 2007 × 2853 – aufgeklappt (noch aufzunehmen, siehe unten)
      Creative/           header-3840x1646.png (Kopfzeile der Produktseite), search-3840x2560.png (Suchergebnisse)
    raw/                  Rohaufnahmen aus dem Simulator
  Tools/
    capture-screenshots.sh      Rohaufnahmen iPhone 18 Pro Max und iPad Pro 13" mit Demo-Daten
    capture-duo-screenshots.sh  dasselbe fürs iPhone Duo, je Display ein Lauf
    compose-screenshots.swift   Überschrift, Rahmen, Hintergrund in den Farben des App-Icons
    check-lengths.py            prüft die Zeichengrenzen der Texte
docs/privacy.md, docs/support.md  Datenschutz und Support (GitHub Pages aus docs/)
```

## Screenshots neu erzeugen

```bash
AppStore/Tools/capture-screenshots.sh            # oder nur ein Gerät: … iphone bzw. … ipad, danach einzelne Motive
AppStore/Tools/capture-duo-screenshots.sh outer  # Duo zugeklappt und hochkant
AppStore/Tools/capture-duo-screenshots.sh inner  # Duo vorher im Device Hub aufklappen
swift AppStore/Tools/compose-screenshots.swift
```

Die App startet dabei mit `-screenshot <Motiv>` (nur in Debug-Builds, `ScreenshotScreen` in
`App/Model/AppModel.swift`): Sie öffnet die Demo direkt an der gewünschten Stelle und blendet „Demo“ und
„Exit Demo“ aus. Alle Server, Pakete und Container sind erfundene Demo-Daten, es wird nichts aus dem Netz geladen.
Überschriften ändern: `english` und `german` in `compose-screenshots.swift`.

- Das **iPad** muss im Querformat liegen. Nach einem Neustart des Simulators steht es wieder hochkant – einmal
  drehen, das Skript warnt bei falscher Größe.
- Das **iPhone Duo** lässt sich nicht per Skript falten. Für `inner` im Device Hub aufklappen, für `outer`
  zuklappen und hochkant halten. Sonst bricht das Skript mit einer Meldung ab, statt schwarze Bilder zu sammeln.
- Uhrzeit in der Statusleiste: 9:41 (beim Duo nur die Uhrzeit, mehr nimmt sein Simulator nicht an).

## Vor dem Einreichen

### Muss noch erledigt werden
- [ ] **Duo innen aufnehmen:** Device Hub → „NAS Cockpit Shots Duo“ aufklappen, dann
  `capture-duo-screenshots.sh inner` und `compose-screenshots.swift`. Duo-Screenshots sind bis April 2027
  freiwillig, bringen aber das Duo-Abzeichen auf der Produktseite.
- [ ] **GitHub Pages einschalten** (Repo-Einstellungen → Pages → Branch `main`, Ordner `/docs`), damit
  Datenschutz- und Support-URL erreichbar sind:
  - Datenschutz: https://rainerzufall00.github.io/NASCockpit/privacy
  - Support: https://rainerzufall00.github.io/NASCockpit/support
- [ ] **Review-Kontakt:** Telefonnummer in `review_information/phone_number.txt` (nicht committen).
- [ ] **CloudKit nach Production deployen:** Schema von `iCloud.com.nascockpit.app` in der CloudKit Console von
  Development nach Production übernehmen, sonst schlägt der iCloud-Sync in der App-Store-Version fehl.
- [ ] **Push-Umgebung:** `aps-environment` steht in den Entitlements auf `development`. Beim Export für den App
  Store setzt Xcode `production` – im Archiv kurz prüfen.
- [ ] **Version:** `MARKETING_VERSION` steht auf 0.1, Build 1. Für den Release 1.0 setzen (App und Widgets),
  archivieren und hochladen.
- [ ] **Name prüfen:** Ist „NAS Cockpit“ im App Store frei? App Store Connect meldet es beim Anlegen.
- [ ] **README:** Der Abschnitt „Status“ sagt noch „not yet on the App Store“ – nach der Freigabe anpassen.
- [ ] Optional: **Multicast-Entitlement** (`com.apple.developer.networking.multicast`) bei Apple beantragen, damit
  Wake-on-LAN als Broadcast funktioniert.

### App Store Connect – Angaben

| Feld | Wert |
| --- | --- |
| Hauptsprache | Englisch (USA), dazu Deutsch – die Oberfläche der App ist Englisch |
| Name | NAS Cockpit (11/30) |
| Untertitel | Your homelab at a glance (24/30) · Dein Homelab auf einen Blick (28/30) |
| Kategorie | Dienstprogramme, zweite Kategorie Entwickler-Tools |
| Preis | Kostenlos, keine In-App-Käufe |
| Bundle-ID | com.nascockpit.app (Widgets: com.nascockpit.app.widgets) |
| Copyright | 2026 RainerZufall00 |
| Datenschutz-URL | https://rainerzufall00.github.io/NASCockpit/privacy |
| Support-URL | https://rainerzufall00.github.io/NASCockpit/support |
| Marketing-URL | https://github.com/RainerZufall00/NASCockpit |
| Exportkontrolle | Keine eigene Verschlüsselung – `ITSAppUsesNonExemptEncryption = NO` ist gesetzt |

**Marken in Untertitel und Keywords:** Synology und Proxmox stehen bewusst nur in der Beschreibung (mit Hinweis,
dass die App unabhängig ist). In Name, Untertitel und Keywords lehnt das Review fremde Marken oft ab
(Richtlinie 2.3.7 / 5.2.1). Die Keywords nutzen deshalb Gattungsbegriffe wie `dsm`, `pve`, `nas`, `homelab`.
Wer mehr Sichtbarkeit riskieren will, kann „for Synology & Proxmox“ in den Untertitel nehmen – mit dem Risiko
einer Rückfrage.

### App-Datenschutz („Nutzungsdaten“)

**„Daten werden nicht erfasst“.** Der Entwickler empfängt keinerlei Daten: Die App spricht nur mit den eigenen
Servern der Nutzer. Der iCloud-Sync liegt in der privaten CloudKit-Datenbank der Nutzer (sensible Felder
Ende-zu-Ende-verschlüsselt), der Entwickler kann sie nicht lesen. Nach Apples Definition gilt das nicht als
„erfasst“. `PrivacyInfo.xcprivacy` (App und Widgets) passt dazu: kein Tracking, keine erfassten Datentypen,
UserDefaults mit den Gründen CA92.1 und 1C8F.1 (App-Gruppe für die Widgets).

### Altersfreigabe

Alle Fragen mit „Nein“ – ergibt 4+. Keine Inhalte Dritter, kein Webbrowser in der App (OpenID Connect öffnet nur
die Anmeldeseite des eigenen Identity Providers), keine Nutzerkonten, kein Chat, keine Werbung.

### Creative Assets (Kopfzeile und Suchergebnisse)

In App Store Connect unter der Asset-Bibliothek pro Sprache hochladen: `header-3840x1646.png` als Kopfzeile der
Produktseite, `search-3840x2560.png` für die Suchergebnisse. Apple beschneidet die Bilder stark und legt Icon,
Name und Laden-Knopf darüber; alles Wichtige steht deshalb mittig. Vorher mit der Vorschau in App Store Connect
prüfen. Ohne Suchbild nimmt Apple die Screenshots.

### Review-Hinweise

Stehen auf Englisch in `review_information/notes.txt`: kein Login nötig, die Demo über „Try the Demo“, Ablauf
zum Testen, Berechtigungen, externe Dienste und der Hinweis auf fremde Marken.
