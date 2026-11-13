# NAS Cockpit – technical notes

Native iOS/iPadOS app (iOS 26+, Swift 6, SwiftUI) for managing several Synology NAS (DSM 7.2+) at once.
The architecture is described in [Architekturplan.md](Architekturplan.md) (German);
what is still planned is in [ROADMAP.md](../ROADMAP.md).

## Structure

```
NASCockpit.xcodeproj    App target (iPhone + iPad, Mac disabled), shared scheme
Widgets/                Widget extension (reads only the app-group status cache)
App/                    Entry point, ConnectionManager, navigation, onboarding, add-server flow, prompts
Config/Info.plist       ATS exception for HTTP in the local network / VPN (merged with the generated plist)
Packages/Core/          Local Swift package
  Domain/               Platform-neutral models, ServerBackend + CredentialProvider protocols,
                        OperationCenter (write queue: sequential per NAS, parallel across NAS)
  Networking/           PinnedTransport (ephemeral URLSession per NAS), SPKI pinning, address selection
  SecurityKit/          Keychain (foreground + background copy), app lock, Face ID gate
  Persistence/          SwiftData profiles, app-group status cache
  SynologyBackend/      DSM client: catalog, login/OTP/device token, re-login, endpoints, mapping
  ProxmoxBackend/       Proxmox VE client: ticket/TOTP, API token, OpenID Connect, tasks, mapping
  DemoBackend/          MockBackend for demo mode, previews and screenshots
  DesignSystem/         Tiles, usage bars, formatting, operation status and activity sheet
  DashboardFeature/ PackagesFeature/ UpdatesFeature/ ContainersFeature/ LogsFeature/
  ControlPanelFeature/ FilesFeature/ BackupFeature/ SnapshotsFeature/ InboxFeature/
  VirtualMachinesFeature/   VMs and containers (Proxmox) / Virtual Machine Manager (DSM)
```

`SecurityKit` is named that way because a module called `Security` would shadow Apple's framework.

## Build & test

Open `NASCockpit.xcodeproj` in Xcode and run the `NASCockpit` scheme, or from the command line:

```bash
xcodebuild -project NASCockpit.xcodeproj -scheme NASCockpit -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

```bash
cd Packages/Core && xcodebuild test -scheme Core-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

In the simulator, saved passwords need Face ID enrolled (Features → Face ID → Enrolled), because the
Keychain items require user presence.

## Status

Phase 1 "Fundament": multi-address selection, TLS with SPKI pinning (TOFU), Keychain, login with OTP and
device token, single shared re-login on 106/119, stop on 407, overview, dashboard with live charts,
packages, aggregated updates, logs with filter/search/export, demo mode, optional app lock.

Phase 2 "Schreiben":
- Packages: update, start, stop (confirmation names the action and the NAS).
- Bulk updates: multi-select in Updates, one sheet grouped by NAS, one Face ID; sequential per NAS,
  parallel across NAS. DSM updates are never part of a bulk selection.
- DSM update: single item only, Face ID, restart warning. The connection goes to `rebooting`, polls with a
  growing interval (10 s → 60 s, 45 min deadline) and signs in again by itself; the tile shows "Restarting…".
- Container Manager: containers and Compose projects; start/stop/restart containers, logs (search, export);
  projects start/stop/rebuild only.
- Writes are never retried. A 105 hides the action for that NAS without a re-login. Destructive actions
  always ask for Face ID, independent of the app lock. An Activity sheet lists running and finished
  operations; the app asks iOS for background time while operations run.

After phase 2:
- HTTP per address, only for hosts in the home network or a VPN (private IPv4, Tailscale 100.64/10 and
  `*.ts.net`, link-local, IPv6 ULA, `.local`, names without a dot). Public hosts are refused for HTTP in the
  add-server form, the request builder and the transport. Existing profiles stay HTTPS.
- Control Panel: DSM automatic update policy, users (disable with Face ID / enable; never the account the
  app signs in with), who is signed in now, SSH on/off, restart and shut down (Face ID).
- File Station (pulled forward from phase 3): browse shared folders, copy or move single files and folders
  with a folder picker, create folders. Existing items in the destination are skipped, never replaced.
- Hyper Backup: tasks with destination, last result, last and next run and live progress; "Back Up Now"
  and "Cancel Backup" with confirmation. The app only starts or cancels; the backup runs on the NAS.
  Each destination is checked (cached for a minute) and shown as "Destination offline". A start is refused
  while the destination is offline, and a run that ends right after the start is reported as an error
  (alert plus a note on the task page).
- Snapshot Replication: snapshots per shared folder (newest first, locked / immutable / scheduled), "Take
  Snapshot Now" with an optional description; replication plans with direction, last and next sync and live
  progress, "Sync Now" on the sending NAS. Shares without snapshot support are left out.
- UI pass: coloured icon badges, gauge rings on tiles and a hero card per NAS, overview summary pills,
  user detail page with an explicit "Disable/Enable Account" button (plus swipe and context menu).
- Logs: System, Connections and Hyper Backup as separate sources. Without `logtype` DSM returned only one
  category (seen: certificate entries); the app now sends `logtype=system|connection` as plain strings
  (like open-source clients) and steps down to JSON values, `logtype` only and finally paging only when DSM
  answers with an API error (seen: 5017). Level and date are filtered on the device.
- Hyper Backup log (`SYNO.SDS.Backup.Client.Common.Log`): all tasks, or one task from its detail page
  (matched by the "[Local][Task]" / "[Network][Task]" prefix).

Known limitation: signing in again after a DSM restart reads the password from the Keychain, which needs
user presence. If the app was in the background for the whole restart, the user may have to tap
"Try again" once the NAS is back.

### Wake-on-LAN

- "Wake Up" appears when a server is not reachable and has a MAC address. The app sends the magic packet
  (UDP ports 9 and 7, three times) to the known subnet broadcast, `x.y.z.255` of each LAN address,
  255.255.255.255 and the LAN address itself, then reconnects every 10 s for up to five minutes.
- Synology fills in the MAC address and broadcast on connect (`SYNO.Core.System` `info`, `type=network`, UNVERIFIED);
  for Proxmox it is entered by hand. VPN addresses are skipped: a sleeping server is not in the VPN.
- iOS only sends broadcasts with the `com.apple.developer.networking.multicast` entitlement, which has to be
  requested from Apple. Without it only the direct packet leaves, and the app says so.

### iCloud sync

- The SwiftData profile store syncs through the private CloudKit database `iCloud.com.nascockpit.app`
  (Settings → iCloud Sync, on by default, applies after a restart).
- Synced, end-to-end encrypted (`allowsCloudEncryption`): name, addresses, user name, pinned certificate, MAC address.
  Synced in the clear: colour, icon, order, notification choices.
- Never synced: passwords, API tokens, the 2FA device token (Keychain, `ThisDeviceOnly`), and the per-device
  choices "save password" and background refresh (`DeviceProfileSettings` in UserDefaults).
  A profile from another device asks for the password once ("Sign In").
- The same NAS added on two devices (same backend, user and one shared address) merges into the profile with the
  smaller UUID on every device; the other's addresses are added and its Keychain items renamed.
- Conflicts: the last change wins (CloudKit default). Debug builds use the CloudKit development environment;
  before a TestFlight or App Store build, deploy the schema to production in the CloudKit console.

### Must be verified against a real DSM

Marked `UNVERIFIED` / `TODO(verify)` in `DSMEndpoints.swift`, `DSMWriteEndpoints.swift` and
`DSMConnection.swift`:
- Read: login `session` name, `SYNO.Core.Package.Server` for available updates, `SYNO.Core.Upgrade.Server`,
  `SYNO.Core.SyslogClient.Log` parameters.
- Packages: `SYNO.Core.Package.Control` start/stop (`id`), `SYNO.Core.Package.Installation` upgrade
  (`name`, `blqinst`) and `status` (`task_id`).
- DSM update: `SYNO.Core.Upgrade.Server.Download` start/progress, `SYNO.Core.Upgrade` start; how DSM
  behaves during the installation phase before the restart.
- Container Manager: `SYNO.Docker.Container` list/start/stop/restart (JSON-encoded `name`),
  `SYNO.Docker.Container.Resource`, `SYNO.Docker.Container.Log`, `SYNO.Docker.Project` list/start/stop/build
  (JSON-encoded `id`).

- Control Panel: `SYNO.Core.Upgrade.Setting` get/set (`autoupdate_enable`, `autoupdate_type`, `schedule`),
  `SYNO.Core.User` list/set (`expired`), `SYNO.Core.Terminal` get/set (`enable_ssh`, `ssh_port`),
  `SYNO.Core.CurrentConnection` list, `SYNO.Core.System` reboot/shutdown.
- Hyper Backup: `SYNO.Backup.Task` list (`additional`, `task_list`, status and result words), `backup`
  (`task_id`), `cancel` (`task_id_list`). Mapping is lenient; unknown words show as "Unknown".
  Destination check: `status` with `task_id` and `blOnline=true`; the app looks for an `…online…` flag or
  words like "offline" / "unavailable" in the state fields. Field names are guessed: if a real DSM answers
  differently, the status simply stays unknown and nothing is blocked.
- Snapshot Replication: `SYNO.Core.Share.Snapshot` list (v2, plain `name`, `limit=-1`) / create (`snapinfo`
  JSON), `SYNO.DR.Plan` list (`additional`) / sync (`plan_id`, `nowait`, `is_send_encrypted`), shapes from
  the open-source synology-api library.
- Logs: which `SYNO.Core.SyslogClient.Log` parameters DSM 7.2 accepts (`logtype` values, plain vs. JSON).
- Hyper Backup log: `SYNO.SDS.Backup.Client.Common.Log` list (`offset`, `limit`, `filter_keyword`,
  `filter_date_from/to`; `log_list` with `event`, `level`, `time`, `user`).
- File Station follows the official API guide (List v2, CopyMove v3, CreateFolder v2) but is not yet
  tested against a real NAS either.

The JSON fixtures in `Tests/SynologyBackendTests/Fixtures` are synthetic and should be replaced with
anonymized real responses.

Next (phase 3 "Hintergrund & Dateien"): opt-in background refresh, local notifications, widgets, File Station
uploads/downloads with background transfers. Localization (German) is still open; all UI strings are English source strings.

Phase 3 "Hintergrund" (first part):
- Background refresh, opt-in per NAS (Settings → Background Refresh & Notifications). A `BGAppRefreshTask`
  signs in with the background Keychain copy, reads status, updates and containers, writes the status
  cache, reloads the widgets and signs out. Read-only. A sign-in or certificate failure pauses the refresh
  for that NAS until the user signs in in the app (never a second attempt, so Auto Block is not triggered).
- Local notifications from `HealthEventDetector` (Domain): storage problems, new package updates, DSM
  update, container exited with a code ≠ 0, Hyper Backup run failed or finished with skipped files. Each
  reports once; the five types can be switched per NAS. "NAS offline" is never reported.
- Notification options (app-wide): volume warning level (80–95 %, default 90 %) and quiet hours, during
  which notifications arrive silently (`.passive`) instead of being held back.
- Tapping a notification opens its NAS; the widgets open their NAS or the updates list
  (`nascockpit://server/<uuid>`, `nascockpit://updates`).
- Widgets: small "NAS Status" (pick the NAS by editing the widget) and medium "Open Updates" across all
  NAS. Without background refresh they show what the app saw last.
- App and widget share the app group `group.com.nascockpit.shared` (entitlements in `Config/`). On a real
  device the group has to exist for the development team; Xcode's automatic signing registers it.

- Notification inbox (sidebar → Notifications): DSM's own notification list (`SYNO.Core.DSMNotify`,
  `action=load`, read-only) of all connected NAS in one list, grouped by day, with a "problems only"
  filter and a detail sheet. DSM sends an event tag plus template variables, not text; the app has its
  own titles for the tags seen so far (`DSMNotifyEndpoints.swift`) and shows unknown tags in a readable
  form. Built against a response captured from a real DSM 7; add titles as new tags turn up.

Notification diagnostics (Settings → Background Refresh & Notifications → NAS): permission state,
Background App Refresh state, Low Power Mode, "Send Test Notification" (arrives after 5 s) and "Check Now",
which runs the same detection as the background refresh over the open connection. iOS runs the background
task only every few hours at best, not at all in Low Power Mode, and only after it learned the usage pattern
of a freshly installed build. The background run keeps a 15 s budget per NAS so iOS does not end it early.

File Station: delete files and folders (recursive, `SYNO.FileStation.Delete` start/status, Face ID, confirmation).
File names are shown in full.

### Proxmox VE

A second adapter (`ProxmoxBackend`) behind the same `ServerBackend` protocol. Add a server of type
"Proxmox VE" (port 8006, HTTPS only, self-signed certificates pinned by SPKI like DSM).

- Sign-in: password (+ TOTP at every sign-in, PVE has no "remember device"), API token
  (`user@realm!name` + secret, created under Datacenter → Permissions → API Tokens, privilege separation
  off or with its own permissions) or OpenID Connect. OpenID runs in an `ASWebAuthenticationSession`
  (passkeys work); the app passes `nascockpit://oidc` as redirect URL, so this URI has to be allowed for the
  Proxmox client in the identity provider. After the browser sign-in the app offers to create an API token
  for the account (`POST /access/users/{user}/token/{name}`, privsep 0), stored in the Keychain, so later
  sign-ins and background refresh need no browser. Tickets are renewed after an hour; a 401 triggers exactly
  one re-login.
- Virtual Machines: all guests of the cluster (`/cluster/resources?type=vm`), grouped by node; start,
  shut down (ACPI), stop, reboot with confirmation; each action waits for its task (`/tasks/{upid}/status`).
  Templates and locked guests are read-only. A 403 hides the action for that host.
- Dashboard: node status, storages (plus the root file system) as volumes, disks with SMART summary,
  network throughput from `rrddata`.
- Backups: vzdump jobs (`/cluster/backup`) with schedule, next run and the last result taken from the
  vzdump task history of the node(s); "Back Up Now" replays the job's settings through `/nodes/{node}/vzdump`,
  "Cancel" stops the running vzdump task. The backup log is the vzdump task list.
- Host updates: `GET /nodes/{node}/apt/update` in the aggregated Updates list, "Check for Updates" runs
  `apt update` on the host. The Proxmox API has no call that installs updates, so they are listed only
  (notified by the background refresh like package updates) and installed in the host shell.
- Host: restart and shut down (`/nodes/{node}/status`), the app waits for the host to come back.
- Logs: journal (`/nodes/{node}/syslog`) and sign-ins (`service=pvedaemon`).
- Open Shell: the host page and every running guest offer "Open Shell", which hands `ssh://user@host:port`
  to an external terminal app (WebSSH, Termius, Blink, Prompt …). Settings → Terminal App sets user, port
  and the link template for apps with their own scheme. Guest addresses come from the QEMU guest agent
  (VMs) or the container's interfaces.
- Open via Host (containers): copies `pct enter <id>` to the clipboard and opens the Proxmox host in the
  terminal app; the user pastes the command after the login. No SSH server or password is needed in the
  container. On another cluster node the command becomes `ssh -t <node> pct enter <id>`, for a non-root
  SSH user it starts with `sudo`. The first tap explains this; "How does this work?" explains it in full.
  An ssh:// link cannot carry a command, so the paste step stays.
- Snapshots (VMs and containers): list, take (name, description, RAM state for running VMs), roll back
  and delete via `…/{qemu|lxc}/{vmid}/snapshot`; each waits for the task. Roll back and delete need Face ID
  or the passcode. Names follow Proxmox' rules (letter first, `[A-Za-z0-9_-]`, 2–40 characters).
- Updates: "Install via Shell" in the update list copies `apt update && apt full-upgrade` (with `sudo` for a
  non-root SSH user) and opens the host in the terminal app; the API itself cannot install packages.
- Backup jobs: `cluster/backup` returns `prune-backups`, `performance` and `fleecing` as objects; they are
  turned back into property strings for "Back Up Now" (`vzdump`).

Must be verified against a real host: the exact `NeedTFA` / `tfa-challenge` login shape, `next-run` in
`/cluster/backup`, `/lxc/{vmid}/interfaces`, and which vzdump job settings a given PVE release accepts in
`/nodes/{node}/vzdump`. The fixtures in `Tests/ProxmoxBackendTests/Fixtures` are synthetic.

### Synology Virtual Machine Manager

Detected through `SYNO.Virtualization.API.Guest`; the same Virtual Machines screen lists the VMs with vCPUs
and RAM. Start = `poweron`, stop = `poweroff`, shut down = `shutdown`, reboot = shutdown, wait until the VM
is off, `poweron` (`SYNO.Virtualization.API.Guest.Action`). VMM reports no guest addresses, so there is no
"Open Shell" for these VMs. Unverified against a real NAS.

To trigger a background run while debugging on a device, pause in the debugger and run
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.nascockpit.app.refresh"]`.
