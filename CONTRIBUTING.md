# Contributing to NAS Cockpit

Thanks for helping! Bug reports, test results from real hardware and pull requests are all welcome.

## Building

You need Xcode 26 or later. The project has no third-party dependencies.

```bash
git clone https://github.com/RainerZufall00/NASCockpit.git
cd NASCockpit
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
open NASCockpit.xcodeproj
```

In `Config/Secrets.xcconfig` set `DEVELOPMENT_TEAM` to your Apple team ID – needed to run on a device. The file is
ignored by Git. The simulator build works without it; tap **Try the Demo** to use the built-in sample servers.

In the simulator, saved passwords need Face ID enrolled (Features → Face ID → Enrolled), because the Keychain items
require user presence.

### Running your own build on a device

Bundle IDs, the app group and the iCloud container are unique per Apple account. A fork needs its own identifiers
instead of `com.nascockpit.app`, `group.com.nascockpit.shared` and `iCloud.com.nascockpit.app` – search the project
for `com.nascockpit` (build settings, entitlements, `Info.plist` and a few constants in `App/` and
`Packages/Core/Sources/`).

## Tests

```bash
cd Packages/Core
xcodebuild test -scheme Core-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The JSON fixtures in `Packages/Core/Tests/*/Fixtures` are synthetic or anonymized. Anonymized real responses from
your own DSM or Proxmox are a great contribution – please remove host names, IPs, serial numbers, MAC addresses and
user names first.

## Project structure

| Folder | Contents |
|---|---|
| `App/` | App target: entry point, connection manager, navigation, onboarding, add-server flow, settings |
| `Widgets/` | Widget extension (reads only the app-group status cache) |
| `Packages/Core/` | Local Swift package: domain models, networking, Keychain, persistence, the DSM and Proxmox clients, demo backend and all feature screens |
| `Config/` | Build settings, entitlements and Info.plist files |
| `docs/` | Technical notes, architecture plan (German) and README images |

More detail on the architecture and on which endpoints are still unverified is in
[docs/TECHNICAL.md](docs/TECHNICAL.md).

## Guidelines

- Keep the app free of third-party dependencies, trackers and analytics.
- Never log or persist credentials outside the Keychain.
- Destructive actions need a confirmation that names the action and the server, plus Face ID.
- Run the tests before opening a pull request.

If you publish your own build, please use a different name and icon (see the license note in the
[README](README.md#license)).
