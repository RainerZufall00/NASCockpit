# NAS-Admin-App – Architekturplan

Nov 6, 2026 · Arbeitstitel: **NAS Cockpit** (endgültiger Name offen)

## Ziel & Umfang

Eine native App für iOS und iPadOS, mit der Admins mehrere Synology-NAS parallel verwalten: Status sehen, Pakete, DSM und Container aktualisieren und pflegen, Logs prüfen, Dateien verwalten und bei Problemen benachrichtigt werden. Die App wird kostenlos im App Store veröffentlicht, Sicherheit ist deshalb ein Kernziel und kein Nachgedanke.

**Positionierung:** Alle NAS und alle Updates in einer Ansicht, kostenlos, ohne Tracking, mit Zertifikats-Pinning und offen beschriebenem Sicherheitskonzept. Abgrenzung zu bestehenden Apps wie NAS Pro und NASmeister.

**MVP-Funktionen**

- Mehrere NAS gleichzeitig verbinden, mit Übersicht aller Geräte
- Dashboard: CPU, RAM, Netzwerk, Volumes, Temperaturen, Laufzeit
- Package Center: installierte Pakete, verfügbare Updates, Update installieren, Start/Stopp
- Sammelansicht „Updates“: Paket- und DSM-Updates aller NAS, Mehrfachauswahl mit Sammelbestätigung
- DSM-Systemupdates anzeigen und einzeln installieren (mit Neustart-Behandlung)
- Container Manager: Container und Compose-Projekte auflisten, starten, stoppen, neu starten, Logs
- Logs: Systemprotokoll mit Filter nach Zeitraum, Schweregrad und Suche
- File Station: durchsuchen, hoch- und herunterladen, umbenennen, verschieben, löschen
- Hintergrund-Refresh (Opt-in pro NAS) mit lokalen Benachrichtigungen
- Widgets: Status einer NAS (klein), alle NAS mit offenen Updates (mittel)
- Demo-Modus für alle Nutzer, sichtbar im Onboarding

**Nicht-Ziele im MVP**

- Einstellungen (kuratierte Auswahl von 10–15 Einstellungen) → v1.1
- OIDC-Login (kommt als spätere Anmeldeart)
- Proxmox und TrueNAS (Architektur ist vorbereitet, Umsetzung später)
- QuickConnect: Zugriff nur über Host/IP, von unterwegs per VPN
- Nur-Lese-Modus: entfällt. Die Rechte steuert das DSM-Konto, fehlende Rechte (105) blenden Aktionen aus
- Mac (auch „Designed for iPad“ auf Apple Silicon wird deaktiviert)
- DSM 7.1 und älter
- Eigenes Backend, Cloud-Sync, Telemetrie, In-App-Käufe
- Vollständige Abbildung der DSM-Systemsteuerung

**Plattformen:** iOS und iPadOS 26+, Swift 6, SwiftUI. Zielversion DSM 7.2 und neuer.

**Sprachen:** Englisch als Basis (String Catalog), Deutsch als erste Übersetzung.

## Systemüberblick

Die App ist in fünf Schichten aufgebaut. Abhängigkeiten zeigen nur nach unten, und nur die Adapter-Schicht kennt DSM.

&#91;embedded content: Systemarchitektur · 5 Schichten, Persistenz und Sicherheit seitlich\]

Ein DSM-Update betrifft damit nur den SynologyBackend-Adapter. Proxmox und TrueNAS docken später als weitere Adapter an derselben Stelle an.

## Server- und Verbindungsmodell

Jede NAS bekommt ein eigenes, isoliertes Verbindungsobjekt. So laufen beliebig viele Geräte parallel, und der Ausfall einer NAS betrifft nur ihre eigene Kachel.

**Bausteine**

- `ServerProfile` (persistiert): eigene UUID, Anzeigename, **geordnete Adressliste** (`[ServerAddress]` mit Host, Port, Bezeichnung wie „LAN“ oder „Tailscale“), zuletzt erreichte Adresse, Backend-Typ (`synology`), Benutzername, gepinnter SPKI-Fingerabdruck (pro NAS, nicht pro Adresse), Hintergrund-Refresh an/aus, Benachrichtigungs-Matrix, Sortierung, Farbe/Icon.
- `ServerConnection` (Swift `actor`, nur zur Laufzeit): hält Session (`sid`, SynoToken), aktive Adresse, API-Katalog, Verbindungszustand und eine eigene `URLSession`.
- `ConnectionManager` (`@MainActor`, `@Observable`): verwaltet alle `ServerConnection`s, erstellt sie bei Bedarf und baut sie bei Entfernen eines Servers ab.

**Isolation pro NAS**

- Eigene `URLSession` mit `URLSessionConfiguration.ephemeral` und eigenem `HTTPCookieStorage`. Cookies zweier NAS unter derselben Domain mit unterschiedlichen Ports überschreiben sich dadurch nicht.
- Eigener `URLSessionDelegate` für die Zertifikatsprüfung mit dem Fingerabdruck genau dieses Servers.
- Keychain-Einträge über die Server-UUID adressiert, nie über den Hostnamen.

**Adresswahl**

- Beim Verbinden probiert die App zuerst die zuletzt erreichte Adresse, danach die übrigen in der festgelegten Reihenfolge, jeweils mit kurzem Timeout (ca. 2–3 s für den TLS-Handshake).
- Zugangsdaten werden erst gesendet, wenn der TLS-Handshake mit passendem Fingerabdruck bzw. gültiger Systemprüfung abgeschlossen ist.
- Ein abweichender Fingerabdruck gilt beim Durchprobieren als „nicht erreichbar“ (z. B. fremdes Gerät unter 192.168.1.10 im Hotel-WLAN). Die Warnung „Fingerabdruck geändert“ erscheint nur, wenn keine Adresse passt und mindestens eine einen fremden Fingerabdruck geliefert hat.
- Bricht eine Verbindung ab, wird die Adresswahl einmal neu durchlaufen, bevor die Verbindung auf `failed` geht.

**Zustände einer Verbindung**

`disconnected` → `connecting` (inkl. Adresswahl) → `needsOTP` (optional) → `connected` → bei Session-Ablauf `reauthenticating` → `connected`. Während eines DSM-Updates `rebooting` (wartet, bis die NAS wieder antwortet, dann automatischer Re-Login). Bei Fehlern `failed(reason)` mit Retry durch den Nutzer.

**Re-Login**

- Läuft eine Anfrage auf Fehlercode 106 (Session-Timeout) oder 119 (SID nicht gefunden), startet der Actor genau einen Re-Login. Alle wartenden Anfragen hängen sich an denselben `Task` und werden danach einmal wiederholt.
- Maximal ein Re-Login-Versuch pro Anfrage. Scheitert er, geht die Verbindung auf `failed`, statt in eine Schleife zu laufen, die den Auto-Block von DSM auslöst.

```swift
actor ServerConnection {
    let profile: ServerProfile
    private let session: URLSession
    private var activeAddress: ServerAddress?
    private var auth: AuthState = .none
    private var reauthTask: Task<Void, Error>?

    func call<R: Decodable>(_ request: DSMRequest<R>) async throws -> R {
        do { return try await send(request) }
        catch DSMError.sessionExpired {
            try await reauthenticate()   // teilt sich einen laufenden Task
            return try await send(request)
        }
    }
}
```

**Parallele Abfragen**

Die Übersicht fragt alle NAS per `withTaskGroup` gleichzeitig ab. Jedes Ergebnis kommt als `Result` zurück, damit eine langsame oder offline NAS die anderen nicht blockiert. Timeouts pro Anfrage: 10 s für Status, länger für Uploads.

## Authentifizierung

Im MVP meldet sich die App mit Benutzername, Passwort und optional OTP an. Danach hält ein Device-Token die Anmeldung, sodass das OTP nur beim ersten Login nötig ist. Empfohlen wird ein eigenes Konto in der Gruppe „administrators“ mit 2FA, nicht das eingebaute `admin`.

**Ablauf**

1. `SYNO.API.Info` abfragen: Pfade und Versionen aller APIs holen (siehe DSM-API-Client).
2. `SYNO.API.Auth` / `login` mit `account`, `passwd`, `format=sid`, `enable_syno_token=yes`.
3. Antwortet DSM mit „OTP erforderlich“, fragt die App den Code ab und sendet den Login erneut mit `otp_code`, `enable_device_token=yes` und einem `device_name` (z. B. „NAS Cockpit auf iPhone von …“).
4. Ergebnis: `sid`, `synotoken` und bei 2FA eine Device-ID. Passwort und Device-ID landen im Keychain, `sid` und SynoToken nur im Speicher.
5. Spätere Logins senden Passwort plus Device-ID, ohne OTP.
6. Logout beim Entfernen eines Servers: `SYNO.API.Auth` / `logout`, danach alle Keychain-Einträge dieses Servers löschen (inkl. Hintergrund-Kopie).

**Hinweis zum Konto**

- Meldet sich jemand mit dem eingebauten Konto `admin` an, zeigt die App nach dem Login einmalig einen Hinweis mit Begründung und Anleitung für ein eigenes Admin-Konto.
- Hat das Konto keine 2FA (Login ohne OTP-Abfrage), erscheint im selben Hinweis eine Empfehlung, 2FA zu aktivieren.
- Danach keine weiteren Hinweise.

**Fehler beim Login (Auswahl, beim Bau gegen echte DSM prüfen)**

| Code | Bedeutung | Reaktion der App |
| --- | --- | --- |
| 400 | Konto unbekannt oder Passwort falsch | Fehlermeldung, kein automatischer Retry |
| 401 | Konto deaktiviert | Fehlermeldung |
| 402 | Keine Berechtigung | Hinweis auf Admin-Gruppe |
| 403 | OTP erforderlich | OTP-Eingabe zeigen |
| 404 | OTP falsch | OTP erneut abfragen |
| 407 | IP gesperrt (Auto-Block) | Deutlicher Hinweis, alle Retries stoppen |

**Sitzungsfehler während der Nutzung**

- 105: keine Berechtigung für diese Aktion → Feature ausgrauen, nicht neu einloggen.
- 106 / 119: Session abgelaufen bzw. unbekannt → genau ein Re-Login.
- 107: Session durch doppelten Login beendet → Re-Login und Hinweis.

**Login im Hintergrund (Opt-in pro NAS)**

- Nur für NAS mit aktiviertem Hintergrund-Refresh. Nutzt die Hintergrund-Kopie des Passworts (siehe Sicherheitskonzept) plus Device-ID, also nie mit OTP-Abfrage.
- Beim ersten Login-Fehler im Hintergrund (400–407 oder anderer Auth-Fehler) wird der Hintergrund-Refresh für diese NAS pausiert, bis sich der Nutzer in der App erfolgreich neu anmeldet. Das Widget zeigt dann „Anmeldung nötig“. Kein erneuter Versuch im Hintergrund, damit der Auto-Block von DSM nie ausgelöst wird.
- Netzwerkfehler (NAS nicht erreichbar) pausieren nicht, sie werden nur im Cache als „zuletzt erreicht vor …“ vermerkt.

**Später: OIDC**

DSM ist selbst der OIDC-Client. Die App müsste also den DSM-eigenen SSO-Login durchlaufen und am Ende die Session übernehmen. Das kommt als weitere Implementierung des Protokolls `Authenticator` dazu, ohne den Rest zu ändern. Offener Punkt: Passkey-Logins (z. B. Pocket ID) funktionieren in `WKWebView` ohne Associated Domain voraussichtlich nicht, das braucht einen eigenen Prototyp.

## DSM-API-Client

Der Client ist eine eigene Schicht, die DSM-Eigenheiten vollständig kapselt. Feature-Module sehen nur typisierte Methoden wie `packages()` oder `restartContainer(id:)`, nie rohe Endpunkte.

**Request-Aufbau**

- Alle Aufrufe gehen an `https://<host>:<port>/webapi/<path>` mit den Parametern `api`, `version`, `method` und den API-spezifischen Feldern. Host und Port kommen aus der aktiven Adresse der Verbindung.
- Lesende Aufrufe per GET, schreibende per POST (`application/x-www-form-urlencoded`), Uploads per Multipart.
- Jede authentifizierte Anfrage trägt `_sid` und den Header `X-SYNO-TOKEN`.
- Mehrere Lesezugriffe lassen sich über `SYNO.Entry.Request` bündeln. Das senkt die Zahl der Requests fürs Dashboard und für den Hintergrund-Refresh deutlich.

**API-Discovery und Versionierung**

- Nach dem Login einmal `SYNO.API.Info` / `query` mit `query=all` abfragen und als API-Katalog pro Verbindung cachen (Pfad, minVersion, maxVersion).
- Jeder Endpunkt deklariert die Versionen, die die App unterstützt. Der Client wählt die höchste gemeinsame Version.
- Fehlt eine API (Paket nicht installiert, z. B. Container Manager), meldet der Client `unsupported`. Die UI blendet das Feature dann aus, statt einen Fehler zu zeigen.

**Endpunkte als Typen**

```swift
struct DSMEndpoint<Response: Decodable>: Sendable {
    let api: String            // "SYNO.Core.Package"
    let method: String         // "list"
    let versions: ClosedRange<Int>
    var params: [String: String] = [:]
    let isWrite: Bool
}
```

Alle Endpunkte liegen gesammelt in einem Modul `DSMEndpoints`, gruppiert nach Feature. Bei einer API-Änderung durch ein DSM-Update gibt es genau eine Stelle zum Anpassen.

**Antworten und Fehler**

- DSM antwortet immer mit `{"success": Bool, "data": …, "error": {"code": Int}}`. Ein generischer `DSMEnvelope<T>` dekodiert das.
- Fehlercodes werden in ein `DSMError`-Enum übersetzt: allgemeine Codes (100–119) zentral, API-spezifische Codes pro Endpunkt.
- Dekodierung tolerant: unbekannte Felder ignorieren, optionale Felder großzügig, damit kleine DSM-Änderungen nicht sofort brechen.

**Undokumentierte APIs finden und absichern**

- Quelle: DSM im Browser öffnen, Aktion ausführen, im Netzwerk-Tab die Requests an `entry.cgi` mitlesen. Ergänzend Open-Source-Bibliotheken wie `synology-api` (Python) als Nachschlagewerk.
- Für jeden Endpunkt eine echte Beispielantwort als JSON-Fixture ins Repo legen (anonymisiert). Daraus entstehen die Dekodier-Tests.
- Im Code markieren, welche Endpunkte offiziell dokumentiert sind (File Station, Auth) und welche nicht.

## Feature-Module

Jedes Feature ist ein eigenes Swift-Package-Target mit eigenem Service, ViewModels und Views. Alle Module hängen nur vom Domain-Protokoll ab, nicht direkt von DSM.

| Modul | Inhalt im MVP | DSM-APIs (Kandidaten, beim Bau verifizieren) | Doku | Aufwand |
| --- | --- | --- | --- | --- |
| Dashboard | CPU, RAM, Netzwerk, Disk-I/O live; Volumes mit Füllstand; Temperatur, Laufzeit, DSM-Version | `SYNO.Core.System`, `SYNO.Core.System.Utilization`, `SYNO.Storage.CGI.Storage` | nein | gering |
| Package Center | Liste installierter Pakete, verfügbare Updates, Update installieren, Start/Stopp | `SYNO.Core.Package`, `SYNO.Core.Package.Server`, `SYNO.Core.Package.Installation` | nein | gering–mittel |
| Updates (Sammelansicht) | Paket- und DSM-Updates aller NAS, Mehrfachauswahl, Fortschritt pro NAS | wie Package Center, dazu DSM-Update-APIs | nein | mittel |
| DSM-Update | verfügbare DSM-Version anzeigen, installieren, Neustart überwachen | `SYNO.Core.Upgrade.*` (Kandidat, unbedingt verifizieren) | nein | mittel–hoch |
| Container Manager | Container und Compose-Projekte, Start/Stopp/Neustart, Ressourcen, Logs | `SYNO.Docker.Container`, `SYNO.Docker.Project`, `SYNO.Docker.Container.Log` | nein | mittel |
| Logs | Systemprotokoll, Filter nach Zeitraum und Schweregrad, Suche, Export als Text | `SYNO.Core.SyslogClient.Log` | nein | gering |
| File Station | Ordner durchsuchen, Vorschau, Upload/Download, Umbenennen, Verschieben, Löschen, Freigabelinks | `SYNO.FileStation.*` | ja | mittel–hoch |
| Hintergrund & Benachrichtigungen | BGAppRefreshTask, Ereigniserkennung, lokale Benachrichtigungen, Widget-Cache | nutzt Dashboard-, Storage-, Package-, Upgrade- und Docker-Endpunkte (nur lesend) | – | mittel |
| Widgets | klein: eine NAS; mittel: alle NAS mit offenen Updates | keine (nur App-Group-Cache) | – | gering |
| Einstellungen (v1.1) | kuratierte Auswahl, z. B. Netzwerk, Benachrichtigungen, Energieplan, Updates, Auto-Block | `SYNO.Core.*` (je Einstellung einzeln) | nein | hoch |

**Hinweise pro Modul**

- **Dashboard:** Live-Werte per Polling alle 3–5 s nur bei sichtbarem Screen; Verlauf der letzten Minuten im Speicher, gezeichnet mit Swift Charts.
- **Package Center:** Updates sind lang laufende Aufgaben. Die App startet sie, pollt den Status und zeigt den Fortschritt, auch wenn der Screen gewechselt wird.
- **Updates (Sammelansicht):** Mehrfachauswahl, dann ein Bestätigungsdialog mit allen Paketen gruppiert nach NAS und einmal Face ID. Ausführung pro NAS nacheinander, über mehrere NAS parallel. DSM-Updates erscheinen in der Liste, lassen sich aber nicht in eine Mehrfachauswahl aufnehmen.
- **DSM-Update:** nur einzeln, mit Face ID und Warnung „Die NAS startet neu“. Danach geht die Verbindung auf `rebooting`, die App pollt mit wachsendem Abstand, bis die NAS wieder antwortet, und meldet sich automatisch neu an. Auf der Kachel ist der Neustart sichtbar.
- **Container Manager:** Compose-Projekte im MVP nur starten, stoppen und neu bauen. Ein Editor für `compose.yaml` folgt später.
- **Logs:** Paginiert laden (offset/limit), nie das ganze Protokoll auf einmal.
- **File Station:** Uploads und Downloads über eine Hintergrund-`URLSession`, damit sie beim Wechsel der App weiterlaufen. Löschen landet im Papierkorb der Freigabe, sofern aktiv (Verhalten der API beim Bau prüfen).
- **Einstellungen (v1.1):** jede Einstellung als eigener kleiner Endpunkt mit Lesen und Schreiben. Lieber wenige Einstellungen zuverlässig als viele halb.

## Sicherheitskonzept

Die App hält Admin-Zugangsdaten fremder NAS. Grundsatz: Daten verlassen das Gerät nur in Richtung der NAS des Nutzers, und jede schreibende Aktion ist bewusst.

**Zugangsdaten**

- Passwort und Device-ID im Keychain mit `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: nicht im iCloud-Backup, nicht auf andere Geräte übertragbar.
- Zugriff auf diesen Keychain-Eintrag zusätzlich per `SecAccessControl` mit `.userPresence` (Face ID / Code).
- **Hintergrund-Kopie (nur bei Opt-in pro NAS):** ein zweiter Eintrag mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, ohne `.userPresence`. Nötig, weil Hintergrundläufe meist bei gesperrtem Gerät stattfinden und dort weder Face ID noch `WhenUnlocked`-Einträge verfügbar sind. Nie im Backup, nie auf anderen Geräten. Der Nutzer sieht beim Aktivieren einen deutlichen Hinweis auf diesen Kompromiss. Abschalten löscht die Kopie sofort.
- `sid` und SynoToken nur im Speicher, nie auf Disk. Die App verwirft sie nicht selbst, sondern erst, wenn DSM die Session beendet (Session-Timeout der NAS) oder die App beendet wird.
- Option „Passwort nicht speichern“: dann Login bei jedem Start. Schließt den Hintergrund-Refresh für diese NAS aus.

**Transport und Zertifikate**

- Nur HTTPS. HTTP wird nicht angeboten, auch nicht im LAN.
- Zertifikat besteht die Systemprüfung (z. B. Let's Encrypt beim Zugriff über den passenden Hostnamen): normale Systemprüfung.
- Zertifikat besteht die Systemprüfung nicht (selbstsigniert, oder gültiges Zertifikat beim Zugriff über eine IP bzw. einen anderen Namen): Trust-on-first-use. Beim ersten Verbinden zeigt die App den SHA-256-Fingerabdruck an, der Nutzer bestätigt ihn, die App pinnt den **Public Key (SPKI)** für diese NAS. So blockieren Let's-Encrypt-Erneuerungen mit gleichem Schlüssel nicht.
- Ändert sich der Fingerabdruck an allen Adressen, blockiert die App die Verbindung und zeigt alten und neuen Wert. Beim Durchprobieren mehrerer Adressen gilt die Regel aus „Adresswahl“. Kein globaler Schalter „Zertifikate ignorieren“.
- App Transport Security bleibt aktiv. Die Ausnahme für nicht systemgeprüfte Zertifikate erfolgt ausschließlich im `URLSessionDelegate` pro Server.

**Bedienung**

- App-Sperre per Face ID beim Öffnen und nach Zeit im Hintergrund: optional, ab Werk aus. Bei aktiver Sperre wird der Inhalt im App-Umschalter verdeckt.
- Bewusste Folge: Da die Session nicht von der App verworfen wird, kann bei ausgeschalteter App-Sperre jeder mit dem entsperrten Gerät die offene Session nutzen. Im Onboarding wird die App-Sperre deshalb empfohlen.
- Jede schreibende Aktion (Update, Stopp, Löschen) braucht eine Bestätigung, die nennt, was auf welcher NAS passiert.
- Destruktive Aktionen (Löschen, Paket entfernen, Neustart, DSM-Update, Sammel-Updates) zusätzlich immer mit Face ID, unabhängig von der App-Sperre.
- Kein Nur-Lese-Modus in der App. Was ein Konto darf, entscheidet DSM. Aktionen, die mit 105 abgelehnt werden, blendet die App aus.

**Benachrichtigungen**

- Inhalt: NAS-Anzeigename und Ereignis, z. B. „Keller-NAS: Volume 1 degraded“. Nie Hostnamen, IPs, Benutzernamen oder Pfade. Die iOS-Einstellung „Vorschau zeigen“ gilt zusätzlich.

**Logging und Privacy**

- `os.Logger` mit `privacy: .private` für Hosts, Benutzernamen und Pfade. Passwörter, `sid` und Tokens werden nie geloggt, auch nicht im Debug-Build.
- Keine Analytics, kein Crash-Reporting von Drittanbietern. Optional nur Apples eigene Crash-Reports.
- App-Store-Datenschutzangabe: „Keine Daten erfasst“.

**Empfehlungen an Nutzer (in der App und im Onboarding)**

- NAS nicht direkt ins Internet stellen, Zugriff von unterwegs per VPN (WireGuard, Tailscale). QuickConnect wird nicht unterstützt.
- Eigenes Admin-Konto für die App mit 2FA, Auto-Block in DSM aktivieren.
- App-Sperre aktivieren.

**Vor dem Release**

- Code-Review des Netzwerk- und Keychain-Codes mit Fokus auf TLS, Speicherung und den Hintergrund-Pfad.
- Test gegen eine NAS mit Man-in-the-Middle-Proxy (z. B. mitmproxy), um die Zertifikatsprüfung zu verifizieren, auch beim Durchprobieren mehrerer Adressen.

## Persistenz & Datenfluss

Dauerhaft gespeichert werden nur die Serverprofile und Einstellungen der App. Alles von der NAS ist Laufzeit-Cache und wird bei Bedarf neu geladen.

**Was wo liegt**

| Daten | Speicherort | Lebensdauer |
| --- | --- | --- |
| Serverprofile (Name, Adressliste, SPKI-Fingerabdruck, Hintergrund-Opt-in, Benachrichtigungs-Matrix) | SwiftData, lokal, ohne CloudKit | bis der Nutzer löscht |
| Passwort, Device-ID | Keychain, `WhenUnlockedThisDeviceOnly` + `.userPresence` | bis der Server entfernt wird |
| Passwort-Kopie für Hintergrund (nur bei Opt-in) | Keychain, `AfterFirstUnlockThisDeviceOnly` | bis Opt-in aus oder Server entfernt |
| Session (`sid`, SynoToken) | Speicher des `ServerConnection`-Actors | bis DSM sie beendet oder die App endet |
| API-Katalog | Speicher, pro Verbindung | bis zum nächsten Login |
| Letzter Status pro NAS (für Übersicht, Warmstart und Widget) | App-Group-Container, kleine JSON-Datei | wird bei jeder Abfrage überschrieben |
| Ereignis-Zustand (bekannte Updates, Container-Zustände, gemeldete Probleme) | App-Group-Container, JSON | wird bei jedem Hintergrundlauf aktualisiert |
| App-Einstellungen (Sperrzeit, Polling-Intervall, App-Sperre an/aus) | `UserDefaults` | dauerhaft |

Kein iCloud-Sync der Serverprofile im MVP. Ein späterer Sync darf nur Adressen und Name übertragen, nie Zugangsdaten oder Fingerabdrücke ohne erneute Bestätigung.

**Datenfluss**

View → `@Observable` ViewModel → Feature-Service → `ServerBackend`-Protokoll → `SynologyBackend` → `ServerConnection` → NAS. Antworten laufen als Domain-Modelle zurück, die UI kennt keine DSM-Typen.

**Polling**

- Nur der sichtbare Screen pollt. Dashboard alle 3–5 s, Übersicht aller NAS alle 30 s, Listen nur bei Pull-to-Refresh.
- Polling stoppt beim Wechsel in den Hintergrund und bei Low Power Mode wird das Intervall verdoppelt.
- Lang laufende Aufgaben (Paket-Updates, DSM-Updates, Uploads) pollen ihren Status unabhängig vom sichtbaren Screen, bis sie fertig sind.

**Hintergrund-Refresh (MVP, Opt-in pro NAS)**

- iOS erlaubt kein dauerhaftes Hintergrund-Polling. Ein `BGAppRefreshTask` läuft, wann iOS es zulässt (typisch einige Male am Tag, oft nachts beim Laden), ohne Garantie für den Zeitpunkt.
- Pro Lauf: für jede NAS mit Opt-in Login (Hintergrund-Kopie + Device-ID), Status, Speicher, Updates und Container per gebündelter Abfrage lesen, App-Group-Cache schreiben, Widgets neu laden, Ereignisse auswerten, Logout.
- Nur lesende Aufrufe. Im Hintergrund wird nie etwas auf der NAS verändert.
- Echte Push-Nachrichten bräuchten weiterhin einen Server und sind kein Ziel. Die lokalen Benachrichtigungen decken die wichtigsten Fälle ab, DSM-eigene Benachrichtigungen per Mail oder Synology-Push bleiben die Empfehlung für Ausfälle.

**Ereignisse für Benachrichtigungen**

| Ereignis | Auslöser | Meldung |
| --- | --- | --- |
| Speicher-Problem | Volume degraded oder abgestürzt, Festplatte mit SMART-Warnung, Volume über 90 % | einmal pro Problem, bis behoben |
| Neue Paket-Updates | Updates, die beim letzten Lauf noch nicht bekannt waren | zusammengefasst pro NAS |
| DSM-Update verfügbar | neue DSM-Version oder Sicherheitsupdate | einmal pro Version |
| Container mit Fehler beendet | Container lief beim letzten Lauf und ist jetzt mit Exit-Code ≠ 0 beendet | einmal pro Container und Vorfall |

- Sauber gestoppte Container (Exit-Code 0, per App, DSM oder Compose) lösen nichts aus.
- „NAS offline“ wird nie gemeldet, weil unterwegs ohne VPN jede NAS unerreichbar ist. Widget und Übersicht zeigen stattdessen „zuletzt erreicht vor …“.
- Einstellbar als Matrix: jeder der vier Typen pro NAS einzeln an/aus.

## UI-Konzept iOS/iPadOS

Eine gemeinsame SwiftUI-Codebasis mit `NavigationSplitView`: auf dem iPad drei Spalten, auf dem iPhone automatisch ein Stack. Systemdesign von iOS 26 ohne Versionsverzweigungen.

**Onboarding**

- Startbildschirm mit „NAS hinzufügen“ und „Demo ausprobieren“ (MockBackend mit Beispieldaten).
- Kurze Empfehlungen: VPN statt Internet-Freigabe, eigenes Admin-Konto mit 2FA, App-Sperre.
- Hinweis, dass die App nicht von Synology stammt.

**NAS hinzufügen**

- Anzeigename, eine oder mehrere Adressen (Host/IP, Port, Bezeichnung), Benutzername, Passwort, optional OTP.
- Fingerabdruck bestätigen, falls das Zertifikat die Systemprüfung nicht besteht.
- Optional: Hintergrund-Refresh und Benachrichtigungen aktivieren, mit Hinweis auf die Passwort-Kopie.

**Navigation**

1. **Spalte 1 – Server:** Übersicht aller NAS als Kacheln mit Status (online, Warnungen, verfügbare Updates, Auslastung, „zuletzt erreicht vor …“). Ganz oben die Einträge „Alle“ und „Updates“.
2. **Spalte 2 – Bereiche der gewählten NAS:** Dashboard, Pakete, Container, Logs, Dateien. Nicht verfügbare Bereiche (z. B. ohne Container Manager) werden ausgeblendet. Einstellungen kommen in v1.1.
3. **Spalte 3 – Detail:** Inhalt des Bereichs, z. B. Paketdetails, Container-Logs, Dateivorschau.

**Gesamtübersicht „Alle“**

- Kachel pro NAS mit CPU, RAM, Volumen-Füllstand und Zahl offener Updates.
- Eine offline NAS zeigt nur auf ihrer Kachel einen Fehler.

**Sammelansicht „Updates“**

- Alle verfügbaren Paket- und DSM-Updates aller NAS in einer Liste, gruppiert nach NAS. Das ist das stärkste Argument für die App gegenüber den offiziellen Apps und den bestehenden Alternativen.
- Mehrfachauswahl für Paket-Updates, Sammelbestätigung mit Face ID. DSM-Updates nur einzeln.
- Fortschritt pro NAS und Paket, auch wenn der Screen gewechselt wird.

**Gestaltung**

- Systemkomponenten, SF Symbols, Dynamic Type und Dark Mode von Anfang an.
- Destruktive Aktionen rot und immer mit Bestätigungsdialog (siehe Sicherheitskonzept).
- iPad: Tastaturkürzel für Refresh und Serverwechsel, Kontextmenüs, Drag & Drop in der File Station.

**Widgets (MVP)**

- Kleines Widget: Status einer NAS. Mittleres Widget: alle NAS mit offenen Updates.
- Daten aus dem App-Group-Cache, nie mit Zugangsdaten im Widget-Prozess. Zeigt „zuletzt aktualisiert“ und „Anmeldung nötig“, wenn der Hintergrund-Refresh pausiert ist.
- Ohne Hintergrund-Opt-in zeigt das Widget den Stand der letzten App-Nutzung.

## Erweiterbarkeit

Die UI spricht nur mit dem Protokoll `ServerBackend`. Synology ist der erste Adapter, Proxmox und TrueNAS kommen später als weitere Adapter dazu, ohne dass Views oder ViewModels sich ändern.

```swift
protocol ServerBackend: Actor {
    var capabilities: Set<Capability> { get }   // .dashboard, .packages, .systemUpdate, .containers, .logs, .files, .settings, .vms
    func connect() async throws
    func systemSnapshot() async throws -> SystemSnapshot
    func updates() async throws -> [UpdateItem]
    func containers() async throws -> [ContainerItem]
    func logs(_ query: LogQuery) async throws -> LogPage
    // weitere Methoden je Capability
}
```

- **Capabilities** steuern, welche Bereiche die UI zeigt. Proxmox bringt z. B. `.vms` mit, hat aber keine File Station.
- **Domain-Modelle** (`SystemSnapshot`, `UpdateItem`, `ContainerItem`, `LogEntry`, `HealthEvent`) sind plattformneutral. Jeder Adapter übersetzt seine API-Antworten in diese Typen. Die Ereigniserkennung für Benachrichtigungen arbeitet nur auf Domain-Modellen und funktioniert damit später auch für andere Plattformen.
- **Authenticator** ist ein eigenes Protokoll pro Anmeldeart: `PasswordOTPAuthenticator` (Synology, MVP), später `OIDCAuthenticator` (Synology), `APITokenAuthenticator` (Proxmox), `APIKeyAuthenticator` (TrueNAS).

**Was die späteren Plattformen mitbringen**

| Plattform | API | Anmeldung | Besonderheit |
| --- | --- | --- | --- |
| Proxmox VE | REST, offiziell dokumentiert | API-Tokens mit Privilege Separation | VM-Konsole braucht Passwort-Ticket, nicht Token |
| TrueNAS (25.04+) | JSON-RPC 2.0 über WebSocket | API-Keys bzw. `auth.login_ex` | REST-API entfällt ab Version 27; Keys umgehen 2FA |

TrueNAS braucht dadurch eine zweite Transportschicht (WebSocket statt HTTP). Die Netzwerkschicht deshalb von Anfang an so schneiden, dass `ServerConnection` den Transport nicht fest voraussetzt.

## Projektstruktur, Tests, Release

Ein Xcode-Projekt für die App plus ein lokales Swift Package mit klar getrennten Targets. So bleiben Abhängigkeiten sichtbar und die Kernlogik ist ohne Simulator testbar.

**Targets**

```
App/                    App-Target (iOS + iPadOS, Mac deaktiviert), Einstiegspunkt, Navigation, BGTask-Registrierung
Widgets/                Widget-Extension (MVP)
Packages/Core/
  Domain/               Domain-Modelle, ServerBackend-, Authenticator-Protokolle
  Networking/           ServerConnection, Adresswahl, Transport, TLS-/SPKI-Pinning-Delegate
  Security/             Keychain-Wrapper (Vordergrund- und Hintergrund-Eintrag), App-Sperre, Fingerabdruck-Prüfung
  Persistence/          SwiftData-Modelle, App-Group-Cache, Ereignis-Zustand
  SynologyBackend/      DSM-API-Client, DSMEndpoints, Fehlercodes, Adapter
  Background/           BGAppRefreshTask-Ablauf, Ereigniserkennung, lokale Benachrichtigungen
  Features/
    DashboardFeature/
    PackagesFeature/
    UpdatesFeature/      Sammelansicht, Bulk- und DSM-Updates
    ContainersFeature/
    LogsFeature/
    FilesFeature/
    SettingsFeature/     (v1.1)
  DesignSystem/         gemeinsame Komponenten, Farben, Kacheln
  Localization/         String Catalog (en, de)
```

Feature-Targets hängen von `Domain` und `DesignSystem` ab, nie von `SynologyBackend`. Nur das App-Target setzt alles zusammen.

**Tests**

- **Dekodier-Tests** mit echten, anonymisierten DSM-Antworten als JSON-Fixtures. Das fängt API-Änderungen nach DSM-Updates am schnellsten ab.
- **Verbindungs-Tests** mit einem Mock-Transport: Re-Login bei 106/119, nur ein Re-Login bei parallelen Anfragen, kein Retry bei 407, Adresswahl in der richtigen Reihenfolge, fremder Fingerabdruck wird übersprungen, Warnung nur wenn keine Adresse passt, `rebooting` nach DSM-Update.
- **Hintergrund-Tests:** Pause beim ersten Auth-Fehler, keine Pause bei Netzwerkfehlern, nur lesende Aufrufe, Ereignis-Deduplizierung, Container mit Exit-Code 0 löst nichts aus, Offline löst nichts aus, Benachrichtigungstext ohne Host/IP.
- **Sicherheits-Tests:** Fingerabdruck-Änderung blockiert, keine Zugangsdaten in Logs, Keychain-Attribute beider Einträge korrekt, Hintergrund-Kopie wird beim Abschalten und beim Entfernen gelöscht.
- **Preview-Backend:** ein `MockBackend`, das das Protokoll mit Beispieldaten erfüllt. Damit laufen SwiftUI-Previews, der Demo-Modus und die Screenshots für den App Store ohne echte NAS.
- **Manuell vor dem Release:** gegen mindestens zwei echte NAS mit unterschiedlicher DSM-Version (7.2 und neuer) testen, inkl. DSM-Update mit Neustart, Hintergrund-Refresh bei gesperrtem Gerät und Zugriff über LAN und VPN. Für zusätzliche Versionen eignet sich eine virtuelle DSM-Instanz im Homelab.

**Release**

- Ein gemeinsamer öffentlicher Release mit dem vollständigen MVP, davor eine kurze TestFlight-Runde mit einigen Homelab-Nutzern.
- App-Review: Der Demo-Modus aus dem Onboarding ersetzt einen Testzugang. Keine öffentlich erreichbare Demo-NAS.
- Kostenlos, ohne In-App-Käufe.
- Store-Eintrag auf Englisch und Deutsch.
- Name und Icon ohne Marken von Synology, Proxmox oder TrueNAS. In der Beschreibung ist „kompatibel mit Synology DSM“ unproblematisch.
- Einen kurzen Hinweis in Beschreibung und Onboarding, dass die App nicht von Synology stammt.

## Roadmap & Risiken

Die App entsteht intern in vier Phasen, jede endet mit einem prüfbaren Meilenstein. Erst lesen, dann schreiben: So ist die Sicherheitsbasis getestet, bevor die App etwas auf der NAS verändern kann. Öffentlich erscheint nur der fertige MVP.

&#91;embedded content: Roadmap · 4 Phasen bis zum Release, dann Erweiterungen\] *(Diagramm an die folgenden Phasen anpassen)*

1. **Fundament:** Networking mit Adresswahl, TLS/SPKI-Pinning, Keychain, Login mit OTP und Device-Token, Übersicht, Dashboard, Logs, Updates anzeigen. Demo-Modus.
2. **Schreiben:** Package Center, Sammel-Updates, DSM-Updates mit Neustart-Behandlung, Container Manager.
3. **Hintergrund & Dateien:** Hintergrund-Refresh mit Opt-in, lokale Benachrichtigungen, Widgets, File Station mit Hintergrund-Transfers.
4. **Härtung & Release:** Sicherheitsreview, mitmproxy-Test, Lokalisierung, Store-Eintrag, kurze TestFlight-Runde, öffentlicher Release.

Danach: v1.1 mit Einstellungen, später OIDC und weitere Plattformen.

**Risiken**

| Risiko | Auswirkung | Gegenmaßnahme |
| --- | --- | --- |
| DSM-Update ändert eine undokumentierte API | Ein Feature bricht | Endpunkte zentral, Fixture-Tests, Feature bei `unsupported` ausblenden |
| Sicherheitslücke in der veröffentlichten App | Zugriff auf fremde NAS | Sicherheitskonzept, Code-Review, Test mit mitmproxy |
| Passwort-Kopie ohne Face ID (Hintergrund) | Zugriff bei entsperrtem bzw. einmal entsperrtem Gerät | Nur Opt-in pro NAS, ThisDeviceOnly, deutlicher Hinweis, sofortiges Löschen beim Abschalten |
| App-Sperre ab Werk aus, Session ohne App-Timeout | Offene Session auf entsperrtem Gerät nutzbar | Empfehlung im Onboarding, Face ID bei destruktiven Aktionen immer aktiv |
| Fehlerhafter Re-Login, auch im Hintergrund | Nutzer wird per Auto-Block ausgesperrt | Ein Re-Login pro Anfrage, Stopp bei Code 407, Hintergrund pausiert beim ersten Auth-Fehler |
| DSM-Update aus der App schlägt fehl oder NAS kommt nicht zurück | NAS nicht erreichbar, Vertrauensverlust | Nur einzeln, Face ID, klare Warnung, Neustart-Überwachung mit Hinweis auf die DSM-Weboberfläche |
| Fehlalarme bei Benachrichtigungen | Nutzer schaltet Benachrichtigungen ab | Kein Offline-Alarm, Container nur bei Exit-Code ≠ 0, Deduplizierung, Matrix pro NAS |
| Großer MVP mit einem einzigen Release | Späterer Start | Interne Phasen mit Meilensteinen, Einstellungen bewusst in v1.1 |
| App-Review lehnt ab | Verzögerter Start | Demo-Modus, neutraler Name und Icon |
| Bestehende Apps (NAS Pro, NASmeister) | Wenig Aufmerksamkeit im Store | Klare Positionierung: Multi-NAS-Updates, kostenlos, Sicherheit |
| OIDC mit Passkeys nicht umsetzbar | Feature fehlt | Eigener Prototyp, Passwort + OTP bleibt Fallback |

**Offene Fragen**

- [ ] Endgültiger App-Name (Arbeitstitel „NAS Cockpit“), Verfügbarkeit im App Store und Markenlage prüfen
- [ ] An echter NAS prüfen: Was darf ein Konto außerhalb der Gruppe „administrators“ in DSM 7.2 abfragen?
- [ ] DSM-Update-API (`SYNO.Core.Upgrade.*`) und Verhalten während des Neustarts verifizieren
- [ ] File Station: Landet Löschen über die API im Papierkorb der Freigabe?
- [ ] Welche 10–15 Einstellungen kommen in v1.1?

**Entschieden (06.11.2026)**

- [x] Monetarisierung: komplett kostenlos
- [x] Mindestversion DSM 7.2, iOS/iPadOS 26
- [x] Kein QuickConnect, kein Mac, kein Nur-Lese-Modus
- [x] Einstellungen in v1.1, Hintergrund-Refresh, Widgets und Benachrichtigungen im MVP
- [x] Mehrere Adressen pro NAS mit automatischer Wahl, SPKI-Pinning per TOFU
- [x] Sprachen Englisch und Deutsch, Demo-Modus öffentlich, ein gemeinsamer Release
