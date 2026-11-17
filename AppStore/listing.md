# App Store listing – NAS Cockpit

Everything to paste into App Store Connect. Generated from `AppStore/metadata` by `AppStore/Tools/make-listing.py` – edit the .txt files there, then run the script again. Character counts in brackets (used/limit). Price, App Privacy and age rating: `AppStore/README.md`.

## Shared

- **Primary category:** Utilities / Dienstprogramme
- **Secondary category:** Developer Tools / Entwickler-Tools
- **Copyright:** 2026 RainerZufall00
- **Languages in this file:** en-US

## English (U.S.) (en-US)

### Name (11/30)

```text
NAS Cockpit
```

### Subtitle (24/30)

```text
Your homelab at a glance
```

### Promotional Text (143/170)

```text
Status, updates, containers, VMs and backups of all your Synology NAS and Proxmox hosts – in one native app. No account, no tracking, no relay.
```

### Description (3014/4000)

```text
NAS Cockpit brings every Synology NAS and Proxmox host you run into one native app for iPhone and iPad. Instead of signing in to each web interface and pinching and zooming on a touch screen, you see at a glance what's running, what needs an update and which backup failed.

EVERY SERVER ON ONE SCREEN
• CPU, RAM and storage of every server, with warnings right where you see them.
• All updates in one list: packages, DSM and Proxmox host updates. Select several and install them in one go – one after another per server, in parallel across servers.
• Optional notifications for storage problems, new updates, crashed containers and failed backups. Plus DSM's own notifications, for all servers in one list.
• Home Screen widgets for server status and open updates.
• Wake-on-LAN: wake a sleeping server, and the app reconnects on its own.
• iCloud sync: your servers show up on all your devices, end-to-end encrypted in your own iCloud. Passwords never leave the device.

SYNOLOGY DSM 7.2 AND LATER
• Live dashboard: load, network, temperature, volumes and drives.
• Package Center: update, start, stop. DSM updates with restart monitoring.
• Container Manager: containers and Compose projects, with logs.
• File Station: browse, copy, move, create folders, delete.
• Hyper Backup: tasks, destination status and Back Up Now. Plus Snapshot Replication.
• Virtual Machine Manager, Control Panel (users, SSH, update policy, restart and shut down) and logs by source.

PROXMOX VE
• Sign in with password and TOTP, an API token or OpenID Connect – passkeys work.
• VMs and containers across the cluster: start, shut down, stop, reboot, snapshots.
• Backup jobs with Back Up Now, host updates, journal and sign-in log.
• Open Shell hands the host or guest over to your terminal app, such as WebSSH, Termius, Blink or Prompt.

SECURITY FIRST
Admin credentials for your NAS are about as sensitive as it gets. So:
• Certificate pinning: self-signed certificates work without turning off TLS checks.
• Passwords, API tokens and two-factor device tokens are kept only in this device's keychain.
• Face ID before critical actions such as restart, shut down or delete – independent of the optional app lock.
• Plain HTTP only inside your own network. On the go, use a VPN such as WireGuard or Tailscale.
• No QuickConnect, no relay, no analytics: the app only talks to your own servers.
• Writes are never retried automatically, so a flaky connection can't run an action twice.

FREE AND OPEN
No account, no ads, no tracking, no in-app purchases. The source code is on GitHub. No server at hand? Try everything in the demo.

GOOD TO KNOW
• You need a Synology NAS with DSM 7.2 or later or a Proxmox VE server.
• The server has to be reachable from your iPhone or iPad, at home or through a VPN.

NAS Cockpit is an independent app. It is not affiliated with or endorsed by Synology Inc. or Proxmox Server Solutions GmbH. Synology and DSM are trademarks of Synology Inc. Proxmox is a trademark of Proxmox Server Solutions GmbH.
```

### Keywords (98/100)

```text
nas,homelab,server,dsm,pve,docker,container,vm,backup,updates,monitor,selfhosted,wake on lan,admin
```

### Support URL

```text
https://rainerzufall00.github.io/NASCockpit/support
```

### Marketing URL

```text
https://github.com/RainerZufall00/NASCockpit
```

### Privacy Policy URL

```text
https://rainerzufall00.github.io/NASCockpit/privacy
```

### What's New in This Version (14/4000) – only from the second version on

```text
First release.
```

## App Review Information

### Notes (2594/4000)

```text
No account, no login to any service of ours, no user-generated content, no In-App Purchases. The app is a client for servers the user runs at home (Synology NAS, Proxmox VE). Because reviewers have no such server, the app has a built-in demo with fictional servers.

PURPOSE AND AUDIENCE
Free companion app for people who run a Synology NAS or a Proxmox VE server at home or in a small office. It shows status, updates, containers, backups and logs of all their servers on one screen and lets them run the usual admin tasks (install updates, start/stop containers and VMs, start a backup). The developer runs no servers; the app only connects to the user's own servers.

HOW TO TEST (no credentials needed)
1. Launch the app and tap "Try the Demo".
2. The overview "All NAS" shows four fictional servers: three Synology NAS (one of them unreachable on purpose) and one Proxmox host.
3. Tap "Updates" in the sidebar to see all updates across servers; select some and tap "Update" (simulated).
4. Tap "Home NAS" for its sections: Dashboard, Packages, Containers, File Station, Hyper Backup, Logs and Control Panel.
5. Tap "Proxmox Lab" and "VMs & Containers" to start or stop a guest (simulated).
6. Destructive actions (restart, shut down, delete) ask for Face ID first; in the simulator use Features → Face ID → Matching Face.
7. "Exit Demo" (top right) returns to the welcome screen.
All demo data is generated on the device; nothing is sent anywhere.

PERMISSIONS
- Local Network: to reach the NAS in the user's home network.
- Face ID: to unlock saved credentials and to confirm critical actions.
- Notifications (only if the user turns on background refresh in Settings): local notifications about storage problems, new updates, crashed containers and failed backups.

EXTERNAL SERVICES
- The user's own Synology DSM and Proxmox VE servers, over HTTPS (HTTP is only allowed for private network addresses).
- Apple CloudKit, optional: the user's private database for syncing server profiles (end-to-end encrypted fields). Passwords and tokens are never synced.
- Background App Refresh to check the servers and post local notifications.
- "Open Shell" opens a third-party terminal app chosen by the user via its URL scheme.
No analytics, ads, tracking or third-party SDKs.

THIRD-PARTY TRADEMARKS
NAS Cockpit is an independent app and says so on the welcome screen and in the description. It is not affiliated with Synology Inc. or Proxmox Server Solutions GmbH. It uses the public web APIs of DSM and Proxmox VE that these products offer to clients. Screenshots show fictional demo servers.
```
