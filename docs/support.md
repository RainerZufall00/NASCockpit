# Support – NAS Cockpit

[English](#english) · [Deutsch](#deutsch)

---

## English

NAS Cockpit shows all your Synology NAS and Proxmox VE servers in one native app for iPhone and iPad: status,
updates, containers, virtual machines, backups and logs. The app is free, has no in-app purchases, no
subscriptions and no tracking.

### Contact

- **Email:** [feedback@mail.mueller.ad](mailto:feedback@mail.mueller.ad) – usually answered within a few days
- **Bug reports and ideas:** [GitHub issues](https://github.com/RainerZufall00/NASCockpit/issues)

### Getting started

1. Tap **Add Server** and choose **Synology DSM** or **Proxmox VE**.
2. Enter the address of your server, e.g. `https://nas.local:5001` or `https://pve.local:8006`.
3. Sign in. The first time, the app shows the server's certificate and remembers it (certificate pinning), so
   self-signed certificates work safely.

No server at hand? Tap **Try the Demo** on the first screen to explore the app with fictional servers.

### Frequently asked questions

**Which versions are supported?**
Synology DSM 7.2 or later and Proxmox VE. The app needs iOS 26 or later.

**Can I use the app outside my home network?**
Yes, through a VPN such as WireGuard or Tailscale. The app deliberately does not support Synology QuickConnect
or other relay services, and it refuses plain HTTP for public addresses. Please don't expose your NAS directly
to the internet.

**Which account should I use on my Synology NAS?**
A dedicated admin account with two-factor authentication. The app supports DSM's two-factor codes and can
remember the device, so you don't have to enter a code every time.

**How do I sign in to Proxmox VE?**
With user name, password and – if set up – a TOTP code, with an API token (`user@realm!name` plus secret, created
under *Datacenter → Permissions → API Tokens*), or with OpenID Connect. For OpenID Connect, allow the redirect
URL `nascockpit://oidc` for the Proxmox client in your identity provider. After signing in in the browser, the
app offers to create an API token, so later sign-ins and the background refresh work without the browser.

**Why can't the app install Proxmox updates directly?**
The Proxmox API has no call that installs updates. The app lists them and hands the update command to your
terminal app (WebSSH, Termius, Blink, Prompt …). Choose the app under *Settings → Terminal App*.

**Wake-on-LAN doesn't wake my server.**
Wake-on-LAN must be turned on on the server, and your iPhone has to be in the same network. Without Apple's
multicast permission, iOS only sends the packet directly to the server's IP address, which not every network
passes on to a sleeping server.

**I don't get notifications.**
Turn on *Background Refresh & Notifications* for the server in the app's settings and allow notifications. iOS
decides when the app may refresh in the background, so notifications can take a while.

**Are my passwords synced to iCloud?**
No. iCloud Sync only syncs your server list, end-to-end encrypted. Passwords, API tokens and two-factor device
tokens stay in the keychain of the device on which you entered them.

**Is my data shared with the developer?**
No. The app has no accounts, analytics or tracking and only talks to your own servers. See the
[Privacy Policy](privacy).

NAS Cockpit is an independent app and is not affiliated with or endorsed by Synology Inc. or Proxmox Server
Solutions GmbH.

---

## Deutsch

NAS Cockpit zeigt alle deine Synology-NAS und Proxmox-VE-Server in einer nativen App für iPhone und iPad: Status,
Updates, Container, virtuelle Maschinen, Backups und Protokolle. Die App ist kostenlos und hat keine In-App-Käufe,
keine Abos und kein Tracking. Die Oberfläche ist auf Englisch.

### Kontakt

- **E-Mail:** [feedback@mail.mueller.ad](mailto:feedback@mail.mueller.ad) – Antwort meist innerhalb weniger Tage
- **Fehler melden und Ideen:** [GitHub-Issues](https://github.com/RainerZufall00/NASCockpit/issues)

### Erste Schritte

1. Auf **Add Server** tippen und **Synology DSM** oder **Proxmox VE** wählen.
2. Die Adresse deines Servers eingeben, z. B. `https://nas.local:5001` oder `https://pve.local:8006`.
3. Anmelden. Beim ersten Mal zeigt die App das Zertifikat des Servers und merkt es sich (Zertifikat-Pinning).
   Selbst signierte Zertifikate funktionieren so sicher.

Kein Server zur Hand? Tippe auf dem ersten Bildschirm auf **Try the Demo**, um die App mit erfundenen Servern
auszuprobieren.

### Häufige Fragen

**Welche Versionen werden unterstützt?**
Synology DSM 7.2 oder neuer und Proxmox VE. Die App braucht iOS 26 oder neuer.

**Kann ich die App außerhalb meines Heimnetzes nutzen?**
Ja, über ein VPN wie WireGuard oder Tailscale. Synology QuickConnect und andere Relay-Dienste unterstützt die
App bewusst nicht, und unverschlüsseltes HTTP lehnt sie für öffentliche Adressen ab. Bitte stelle dein NAS nicht
direkt ins Internet.

**Welches Konto sollte ich auf dem Synology-NAS nutzen?**
Ein eigenes Admin-Konto mit Zwei-Faktor-Anmeldung. Die App unterstützt die Zwei-Faktor-Codes von DSM und kann
sich das Gerät merken, sodass du nicht jedes Mal einen Code eingeben musst.

**Wie melde ich mich bei Proxmox VE an?**
Mit Benutzername, Passwort und – falls eingerichtet – einem TOTP-Code, mit einem API-Token (`user@realm!name`
und Secret, angelegt unter *Datacenter → Permissions → API Tokens*) oder über OpenID Connect. Für OpenID Connect
erlaubst du im Identity Provider beim Proxmox-Client die Redirect-URL `nascockpit://oidc`. Nach der Anmeldung im
Browser bietet die App an, ein API-Token anzulegen. Spätere Anmeldungen und die Hintergrundaktualisierung
kommen dann ohne Browser aus.

**Warum installiert die App Proxmox-Updates nicht direkt?**
Die Proxmox-API hat dafür keinen Aufruf. Die App zeigt die Updates an und übergibt den Befehl an deine
Terminal-App (WebSSH, Termius, Blink, Prompt …). Welche App, stellst du unter *Settings → Terminal App* ein.

**Wake-on-LAN weckt meinen Server nicht.**
Wake-on-LAN muss auf dem Server eingeschaltet sein, und dein iPhone muss im selben Netz sein. Ohne Apples
Multicast-Berechtigung schickt iOS das Paket nur direkt an die IP-Adresse des Servers. Das reicht nicht in jedem
Netz, um einen schlafenden Server zu erreichen.

**Ich bekomme keine Mitteilungen.**
Schalte in den Einstellungen der App für den Server *Background Refresh & Notifications* ein und erlaube
Mitteilungen. Wann die App im Hintergrund aktualisieren darf, entscheidet iOS – Mitteilungen können also etwas
dauern.

**Werden meine Passwörter in iCloud synchronisiert?**
Nein. Der iCloud-Sync überträgt nur deine Serverliste, Ende-zu-Ende-verschlüsselt. Passwörter, API-Tokens und
Zwei-Faktor-Gerätetokens bleiben im Schlüsselbund des Geräts, auf dem du sie eingegeben hast.

**Werden meine Daten mit dem Entwickler geteilt?**
Nein. Die App hat keine Konten, keine Analyse und kein Tracking und spricht nur mit deinen eigenen Servern. Siehe
die [Datenschutzerklärung](privacy).

NAS Cockpit ist eine unabhängige App und nicht mit Synology Inc. oder der Proxmox Server Solutions GmbH verbunden.
