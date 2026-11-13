# Privacy Policy / Datenschutzerklärung – NAS Cockpit

*Last updated / Stand: 13 November 2026*

[English](#english) · [Deutsch](#deutsch)

---

## English

NAS Cockpit is an app for managing Synology NAS and Proxmox VE servers that **you** run or have access to. The
developer does not run any servers for the app and does not collect any data about you.

### Responsible
Matthias Müller
Email: feedback@mail.mueller.ad

### What the app does not do
- No user account with the developer, no analytics, no advertising, no tracking, no third-party SDKs.
- No data is sent to the developer, unless you write to the developer yourself.
- No Synology QuickConnect or other relay services. The app connects to your servers directly.

### Data that leaves your device, and where it goes

| Data | Recipient | When |
|---|---|---|
| Server address, user name, password or API token, two-factor codes, and the actions you take (for example installing an update or starting a VM) | **Your own Synology NAS or Proxmox VE server** | When you connect, refresh or run an action |
| Your sign-in with the OpenID Connect provider | The provider your Proxmox server is set up with, in the system browser | Only when you sign in with OpenID Connect |
| Server profiles: name, addresses, port, user name, certificate fingerprint, Wake-on-LAN settings, colour and icon | **Your own private iCloud** (Apple CloudKit), with the sensitive fields end-to-end encrypted | When iCloud Sync is on (default; can be turned off in Settings) |
| Wake-on-LAN packet with the server's MAC address | Your local network | Only when you tap *Wake Up* |
| Host name of the server and a shell command | The terminal app you chose (for example WebSSH or Termius) and the clipboard | Only when you tap *Open Shell* |

Passwords, API tokens and two-factor device tokens are **never** synced: they stay in the keychain of the device
on which you entered them. Your servers are operated by you or by someone you chose; their privacy is governed by
whoever runs them. iCloud is provided by Apple, see the [Apple Privacy Policy](https://www.apple.com/legal/privacy/).
The developer has no access to your iCloud data.

### Data stored on your device
- Passwords, API tokens and two-factor device tokens, in the iOS keychain, available only on this device.
- Server profiles, the pinned certificate of each server and your settings.
- The latest status of your servers (for example storage and open updates), shared with the app's widgets.

Deleting the app removes this data. Deleting a server in the app removes its credentials.

### Notifications
If you turn on background refresh, the app checks your servers in the background and shows **local**
notifications, for example about storage problems or failed backups. They are created on your device; no push
service of the developer is involved.

### Permissions
- **Local network** – to reach the servers in your home network.
- **Face ID** – to unlock saved credentials and to confirm critical actions. Face ID data is handled by iOS; the
  app never sees it.
- **Notifications** – only if you turn them on.

### Children
The app is not directed at children and collects no data from anyone.

### Changes
Changes to this policy are published on this page.

---

## Deutsch

NAS Cockpit ist eine App zur Verwaltung von Synology-NAS und Proxmox-VE-Servern, die **du** betreibst oder
nutzt. Der Entwickler betreibt keine Server für die App und erhebt keine Daten über dich.

### Verantwortlich
Matthias Müller
E-Mail: feedback@mail.mueller.ad

### Was die App nicht tut
- Kein Konto beim Entwickler, keine Analyse, keine Werbung, kein Tracking, keine Fremd-SDKs.
- Es werden keine Daten an den Entwickler übertragen, außer du schreibst ihm selbst.
- Kein Synology QuickConnect und keine anderen Relay-Dienste. Die App verbindet sich direkt mit deinen Servern.

### Welche Daten dein Gerät verlassen und wohin

| Daten | Empfänger | Wann |
|---|---|---|
| Server-Adresse, Benutzername, Passwort oder API-Token, Zwei-Faktor-Codes und deine Aktionen (z. B. ein Update installieren oder eine VM starten) | **Dein eigenes Synology-NAS bzw. dein Proxmox-VE-Server** | Beim Verbinden, Aktualisieren und Ausführen von Aktionen |
| Deine Anmeldung beim OpenID-Connect-Anbieter | Der Anbieter, mit dem dein Proxmox-Server eingerichtet ist, im Browser des Systems | Nur wenn du dich über OpenID Connect anmeldest |
| Serverprofile: Name, Adressen, Port, Benutzername, Fingerabdruck des Zertifikats, Wake-on-LAN-Einstellungen, Farbe und Symbol | **Deine eigene private iCloud** (Apple CloudKit), die sensiblen Felder Ende-zu-Ende-verschlüsselt | Wenn der iCloud-Sync an ist (Standard; in den Einstellungen abschaltbar) |
| Wake-on-LAN-Paket mit der MAC-Adresse des Servers | Dein lokales Netzwerk | Nur wenn du auf *Wake Up* tippst |
| Hostname des Servers und ein Shell-Befehl | Die Terminal-App deiner Wahl (z. B. WebSSH oder Termius) und die Zwischenablage | Nur wenn du auf *Open Shell* tippst |

Passwörter, API-Tokens und Zwei-Faktor-Gerätetokens werden **nie** synchronisiert: Sie bleiben im Schlüsselbund
des Geräts, auf dem du sie eingegeben hast. Deine Server betreibst du selbst oder jemand deiner Wahl; für deren
Datenschutz ist der jeweilige Betreiber verantwortlich. iCloud wird von Apple bereitgestellt, siehe die
[Datenschutzrichtlinie von Apple](https://www.apple.com/de/legal/privacy/). Der Entwickler hat keinen Zugriff auf
deine iCloud-Daten.

### Auf dem Gerät gespeicherte Daten
- Passwörter, API-Tokens und Zwei-Faktor-Gerätetokens, im Schlüsselbund von iOS, nur auf diesem Gerät verfügbar.
- Serverprofile, das gepinnte Zertifikat jedes Servers und deine Einstellungen.
- Der letzte Stand deiner Server (z. B. Speicher und offene Updates), den auch die Widgets der App anzeigen.

Beim Löschen der App werden diese Daten entfernt. Beim Löschen eines Servers in der App werden seine Zugangsdaten
entfernt.

### Mitteilungen
Schaltest du die Hintergrundaktualisierung ein, prüft die App deine Server im Hintergrund und zeigt **lokale**
Mitteilungen, z. B. zu Speicherproblemen oder fehlgeschlagenen Backups. Sie entstehen auf deinem Gerät; ein
Push-Dienst des Entwicklers ist nicht beteiligt.

### Berechtigungen
- **Lokales Netzwerk** – um die Server in deinem Heimnetz zu erreichen.
- **Face ID** – zum Entsperren gespeicherter Zugangsdaten und zum Bestätigen kritischer Aktionen. Die
  Face-ID-Daten verarbeitet iOS; die App sieht sie nie.
- **Mitteilungen** – nur wenn du sie einschaltest.

### Kinder
Die App richtet sich nicht an Kinder und erhebt von niemandem Daten.

### Änderungen
Änderungen dieser Erklärung werden auf dieser Seite veröffentlicht.
