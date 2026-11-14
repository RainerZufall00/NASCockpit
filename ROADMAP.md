# Roadmap

Was für eine vollständige Companion-App für Synology DSM und Proxmox VE noch fehlt. Stand: 11. November 2026.
Erledigt: Proxmox-Snapshots und Proxmox-Updates über die Shell (nicht mehr in dieser Liste).
Noch an echter Hardware zu prüfen: Snapshots auf Speicher ohne Snapshot-Unterstützung und mit eingeschränkten Rechten.

## Zuerst: an echten Geräten prüfen

Diese Schnittstellen sind aus Fremdquellen abgeleitet und noch nicht an echter Hardware getestet.
Erst prüfen, dann weitere Funktionen darauf aufbauen.

- [ ] Hyper Backup: Zielstatus (`SYNO.Backup.Task` `status` mit `blOnline=true`) gegen DSM 7.2.
- [ ] Hyper Backup: Erkennung, dass ein gestarteter Lauf sofort wieder endet.
- [ ] Synology Virtual Machine Manager: Liste, Start, Herunterfahren, Neustart.
- [ ] Proxmox: Anmeldung mit OpenID Connect (Redirect `nascockpit://oidc` beim Identity Provider erlauben).
- [ ] Proxmox: Anmeldung mit Zwei-Faktor-Code (`NeedTFA` / `tfa-challenge`).
- [ ] Proxmox: Backup-Liste und "Back Up Now" mit echten Jobs.
- [ ] Mitteilungen im Hintergrund auf dem iPhone (iOS entscheidet über den Zeitpunkt).
- [ ] Sicherheitsberater: Status (`SYNO.Core.SecurityScan.Status` `system_get`) gegen DSM 7.2, auch während
  eines laufenden Scans (`sysProgress`, `startTime`, `runningItem`).
- [ ] Sicherheitsberater: Liste der Prüfungen (`rule_get` mit `items=ALL`): Form der Antwort und lesbare Titel.
- [ ] Sicherheitsberater: Scan starten (`SYNO.Core.SecurityScan.Operation` `start`, sonst `specific_start`).

## Hoher Nutzen

- [x] **Wake-on-LAN** für Synology und Proxmox: "Wake Up" bei nicht erreichbaren Servern, MAC-Adresse im Profil
  (Synology füllt sie beim Verbinden selbst aus), danach verbindet sich die App bis zu 5 Minuten lang neu.
  - [ ] Am iPhone prüfen. iOS lässt Broadcasts nur mit dem Entitlement `com.apple.developer.networking.multicast`
    zu (bei Apple beantragen). Ohne geht das Paket nur direkt an die IP-Adresse des Servers; die App weist darauf hin.
  - [ ] DSM: `SYNO.Core.System` `info` mit `type=network` (Felder `nif`, `mac`, `mask`) ist UNVERIFIED.
- [ ] **Mehr Mitteilungen**
  - [ ] Proxmox: Gast unerwartet gestoppt.
  - [ ] Proxmox: Knoten offline.
  - [ ] Synology und Proxmox: Speicher fast voll (eigene Schwelle je Speicher).
  - [ ] Hyper Backup: Ziel länger als eine einstellbare Zeit offline.

## Synology

- [ ] **File Station**
  - [ ] Dateien hochladen (aus Dateien-App und Fotos).
  - [ ] Dateien herunterladen und teilen.
  - [ ] Vorschau für Bilder, PDF und Text.
  - [ ] Freigabelinks erstellen (`SYNO.Core.Sharing`), mit Ablaufdatum und Passwort.
- [ ] **Speicher-Manager**
  - [ ] SMART-Schnelltest und erweiterten Test starten, Ergebnis anzeigen.
  - [ ] Datenbereinigung (Scrubbing) starten und Fortschritt zeigen.
  - [ ] Stand einer RAID-Reparatur oder -Erweiterung anzeigen.
- [ ] **Auto Block**: gesperrte IP-Adressen anzeigen und entsperren. Die App meldet den Fall schon,
  das Entsperren geht bisher nur in DSM.
- [ ] **USV**: Zustand, Akkustand und Restlaufzeit der unterbrechungsfreien Stromversorgung.

## Proxmox VE

- [ ] **Backup pro Gast**: einen einzelnen Gast sofort sichern (`vzdump` mit `vmid`), Ziel-Speicher wählbar.
- [ ] **Vorhandene Backups** je Gast auflisten (Speicherinhalt `content=backup`), mit Größe und Notiz.
- [ ] **Speicher**: Zustand der ZFS-Pools, SMART-Werte der Laufwerke, Belegung je Speicher.
- [ ] **Aufgaben**: laufende und letzte Aufgaben mit Protokoll, wie unten in der Proxmox-Weboberfläche.
- [ ] **Diagramme pro Gast**: Verlauf von CPU, RAM und Netzwerk (`rrddata` je Gast).
- [ ] **Proxmox Backup Server** als eigener Servertyp: Datastores, Belegung, Verify- und Prune-Jobs.

- [x] **Sicherheitsberater**: Ergebnis des letzten Scans je Kategorie, nicht bestandene Prüfungen und
  "Scan Now" mit Fortschritt.
  - [ ] Mitteilung, wenn ein Scan neue Risiken findet (Hintergrundaktualisierung).
  - [ ] Sicherheitsstatus aller NAS in der Übersicht.

## Für beide Plattformen

- [ ] **Kurzbefehle und Siri** (App Intents): zum Beispiel "Starte VM homeassistant", "Prüfe Updates",
  "Starte Backup". Schreibende Aktionen nur nach Bestätigung.
- [ ] **Live-Aktivität** für ein laufendes Update oder Backup auf dem Sperrbildschirm.
- [x] **iCloud-Sync** der Serverprofile zwischen iPhone und iPad, Ende-zu-Ende-verschlüsselt. Zugangsdaten
  bleiben im Schlüsselbund des Geräts und werden nicht synchronisiert.
  - [ ] Zwischen iPhone und iPad prüfen: neues Profil, Änderung, Löschen, dieselbe NAS auf beiden Geräten.
  - [ ] Vor TestFlight: CloudKit-Schema in der CloudKit-Konsole nach Production übernehmen.

## Bewusst nicht geplant

Das gehört an den Rechner und würde die App nur größer und angreifbarer machen.

- VM- und Container-Konfiguration ändern (CPU, RAM, Laufwerke, Netzwerk).
- Cluster-Migration, HA-Regeln und Ceph.
- Benutzer-, Gruppen- und Rechteverwaltung.
- Eine Konsole in der App. Shells öffnen sich in der Terminal-App der Wahl.
- Deutsche Übersetzung der Oberfläche: vorerst nicht.
