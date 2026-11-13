import Foundation
import Observation
import UIKit
import DemoBackend
import DesignSystem
import Domain
import InboxFeature
import Networking
import Persistence
import ProxmoxBackend
import SecurityKit
import SynologyBackend
import UpdatesFeature

/// Something the user has to answer before a connection can continue.
enum ConnectionPrompt: Identifiable, Hashable {
    case otp(ServerID)
    case trust(ServerID, CertificateInfo, previousSPKI: String?)
    case password(ServerID)

    var id: String {
        switch self {
        case .otp(let id): "otp-\(id)"
        case .trust(let id, let info, _): "trust-\(id)-\(info.spkiSHA256)"
        case .password(let id): "password-\(id)"
        }
    }

    var serverID: ServerID {
        switch self {
        case .otp(let id), .trust(let id, _, _), .password(let id): id
        }
    }
}

/// Owns one backend per NAS and the runtime state the UI shows. A failing NAS only
/// changes its own entry.
@MainActor
@Observable
final class ConnectionManager {
    struct Runtime: Equatable {
        var state: ConnectionState = .disconnected
        var snapshot: SystemSnapshot?
        var pendingUpdates: Int?
        var lastReached: Date?
        var capabilities: Set<Capability> = []
        /// A Wake-on-LAN packet was sent at this time; the app keeps trying to connect until the server answers.
        var wakingSince: Date?
        var wakeError: String?
        /// iOS blocked the broadcast; the packet only went to the server's address directly.
        var wakeBroadcastBlocked = false
    }

    let isDemo: Bool
    private(set) var profiles: [ServerProfile] = []
    private(set) var runtime: [ServerID: Runtime] = [:]
    private(set) var prompts: [ConnectionPrompt] = []
    /// Shown once when DSM ended a session because of a duplicate login (107).
    var interruptedSessionServer: ServerID?
    /// Write operations (updates, start/stop, DSM update). Keeps running when the user leaves the screen.
    let operations = OperationCenter()

    @ObservationIgnored private var backends: [ServerID: any ServerBackend] = [:]
    @ObservationIgnored private var eventTasks: [ServerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var wakeTasks: [ServerID: Task<Void, Never>] = [:]
    @ObservationIgnored private let repository: ProfileRepository?
    @ObservationIgnored let statusCache: StatusCache?
    /// Baseline and pause flag of the background refresh. Shared with `BackgroundRefresher`.
    @ObservationIgnored let backgroundState: BackgroundStateStore?
    @ObservationIgnored let keychain: KeychainCredentialStore?
    /// Passwords of NAS with "don't save password" – lost when the app ends.
    @ObservationIgnored let sessionCredentials = InMemoryCredentialProvider()

    static var deviceName: String { "NAS Cockpit (\(UIDevice.current.model))" }

    init(repository: ProfileRepository?, statusCache: StatusCache?, backgroundState: BackgroundStateStore? = nil, keychain: KeychainCredentialStore?, isDemo: Bool) {
        self.repository = repository
        self.statusCache = statusCache
        self.backgroundState = backgroundState
        self.keychain = keychain
        self.isDemo = isDemo

        // Destructive actions always need Face ID / passcode, independent of the app lock.
        // Demo mode on a device without passcode (fresh simulator) is the only exception: nothing real happens there.
        operations.authorize = { reason in
            if isDemo, !BiometricGate.isAvailable { return true }
            return await BiometricGate.confirm(reason: reason)
        }
        operations.onFinish = { [weak self] operation in
            Task { await self?.operationFinished(operation) }
        }
    }

    private func operationFinished(_ operation: OperationCenter.Operation) async {
        let id = operation.serverID
        guard backends[id] != nil else { return }
        switch operation.kind {
        case .fileTransfer, .fileDelete, .backup, .snapshot, .replicationSync, .guestSnapshot:
            return
        case .power(.shutDown):
            await refreshSnapshot(id)
            return
        case .systemUpdate, .power(.restart):
            await refreshSnapshot(id)
        default:
            break
        }
        await refreshUpdates(id)
    }

    static func live(repository: ProfileRepository) -> ConnectionManager {
        ConnectionManager(repository: repository, statusCache: StatusCache(appGroupIdentifier: AppConstants.appGroup), backgroundState: BackgroundStateStore(appGroupIdentifier: AppConstants.appGroup), keychain: KeychainCredentialStore(), isDemo: false)
    }

    static func demo() -> ConnectionManager {
        ConnectionManager(repository: nil, statusCache: nil, keychain: nil, isDemo: true)
    }

    // MARK: Lifecycle

    func load() async {
        profiles = repository?.all() ?? DemoData.profiles
        let cached = await statusCache?.load() ?? [:]
        for profile in profiles {
            let status = cached[profile.id]
            runtime[profile.id] = Runtime(snapshot: status?.snapshot, pendingUpdates: status?.pendingUpdates, lastReached: status?.lastReached)
            attach(makeBackend(for: profile), for: profile.id)
        }
    }

    /// Another device changed the profiles (iCloud), or a duplicate appeared. Adds, removes and updates
    /// without touching NAS whose connection details stayed the same.
    func reloadProfiles() async {
        guard let repository else { return }
        if let merges = try? repository.mergeDuplicates() {
            for merge in merges {
                await keychain?.moveAll(from: merge.removed, to: merge.kept)
                await sessionCredentials.remove(merge.removed)
                await statusCache?.remove(merge.removed)
                await backgroundState?.remove(merge.removed)
            }
        }
        let fresh = repository.all()
        guard fresh != profiles else { return }
        let old = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let freshIDs = Set(fresh.map(\.id))
        profiles = fresh

        for (id, _) in old where !freshIDs.contains(id) {
            // Removed on another device (or merged into its twin): forget it here too.
            if let backend = backends[id] { await backend.disconnect() }
            eventTasks[id]?.cancel()
            eventTasks[id] = nil
            wakeTasks[id]?.cancel()
            wakeTasks[id] = nil
            backends[id] = nil
            runtime[id] = nil
            prompts.removeAll { $0.serverID == id }
            if profile(id) == nil {
                try? await keychain?.deleteAll(for: id)
                await sessionCredentials.remove(id)
                await statusCache?.remove(id)
                await backgroundState?.remove(id)
            }
        }

        var toConnect: [ServerID] = []
        for profile in fresh {
            guard let previous = old[profile.id] else {
                runtime[profile.id] = Runtime()
                attach(makeBackend(for: profile), for: profile.id)
                toConnect.append(profile.id)
                continue
            }
            if previous.connectionDetailsDiffer(from: profile) {
                if let backend = backends[profile.id] { await backend.disconnect() }
                runtime[profile.id] = Runtime()
                attach(makeBackend(for: profile), for: profile.id)
                toConnect.append(profile.id)
            }
        }
        // A new profile without a password on this device asks for it ("Sign In"); no Face ID for that.
        if !toConnect.isEmpty, UIApplication.shared.applicationState != .background {
            await connect(toConnect)
        }
    }

    /// Automatic (re)connects only after network problems. Auth failures – above all 407 Auto Block –
    /// need an explicit retry by the user so the app never triggers DSM's IP block.
    private func shouldAutoConnect(_ id: ServerID) -> Bool {
        switch runtime[id]?.state ?? .disconnected {
        case .disconnected: true
        case .failed(let error):
            switch error {
            // credentialsUnavailable is the iPhone's own Keychain (Face ID failed or the app was not on screen),
            // never a failed login at the NAS, so retrying cannot trigger Auto Block.
            case .unreachable, .timeout, .notConnected, .sessionLost, .cancelled, .invalidResponse, .server, .other,
                 .credentialsUnavailable: true
            default: false
            }
        default: false
        }
    }

    func connectAll() async {
        let toConnect = profiles.filter { shouldAutoConnect($0.id) }
        guard !toConnect.isEmpty else { return }

        // One Face ID prompt for all NAS with a saved password.
        if let keychain, toConnect.contains(where: \.savesPassword) {
            do {
                try await keychain.authenticate()
            } catch {
                for profile in toConnect where profile.savesPassword {
                    runtime[profile.id, default: Runtime()].state = .failed(.credentialsUnavailable)
                }
                await connect(toConnect.filter { !$0.savesPassword }.map(\.id))
                return
            }
        }
        await connect(toConnect.map(\.id))
    }

    private func connect(_ ids: [ServerID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.connect(id) }
            }
        }
    }

    /// `interactive`: the user asked for this connect (Try again, Sign In, OTP, trust). Only then may an
    /// OpenID profile without an API token open the browser.
    func connect(_ id: ServerID, otp: String? = nil, interactive: Bool = false) async {
        guard let backend = backends[id] else { return }
        if let proxmox = backend as? ProxmoxBackend {
            await proxmox.setInteractiveSignIn(interactive)
        }
        do {
            try await backend.connect(otp: otp)
            // The `.connected` event arrives asynchronously; without this the first refresh
            // could still see `.connecting` and skip this NAS.
            runtime[id, default: Runtime()].state = .connected
            runtime[id]?.lastReached = .now
            runtime[id, default: Runtime()].capabilities = await backend.capabilities()
            // A successful sign-in in the app lets the background refresh try again.
            await backgroundState?.update(id) { $0.pausedForLogin = false }
            await refreshSnapshot(id)
            await refreshUpdates(id)
            await learnWakeOnLAN(id, from: backend)
        } catch {
            handleConnectError(BackendError(error), for: id)
        }
    }

    private func handleConnectError(_ error: BackendError, for id: ServerID) {
        switch error {
        case .otpRequired, .otpInvalid:
            enqueue(.otp(id))
        case .certificateUntrusted(let info):
            enqueue(.trust(id, info, previousSPKI: nil))
        case .fingerprintChanged(let expected, let observed):
            enqueue(.trust(id, observed, previousSPKI: expected.isEmpty ? profile(id)?.pinnedSPKI : expected))
        default:
            break
        }
    }

    func disconnectAll() async {
        for backend in backends.values { await backend.disconnect() }
    }

    // MARK: Prompts

    private func enqueue(_ prompt: ConnectionPrompt) {
        guard !prompts.contains(where: { $0.serverID == prompt.serverID }) else { return }
        prompts.append(prompt)
    }

    func dismissPrompt(_ prompt: ConnectionPrompt) {
        prompts.removeAll { $0 == prompt }
    }

    func submitOTP(_ code: String, for id: ServerID) async {
        prompts.removeAll { $0 == .otp(id) }
        await connect(id, otp: code, interactive: true)
    }

    func trust(_ certificate: CertificateInfo, for id: ServerID) async {
        prompts.removeAll { $0.serverID == id }
        guard let backend = backends[id] else { return }
        await backend.trustCertificate(certificate)
        await connect(id, interactive: true)
    }

    func signIn(_ id: ServerID, password: String) async {
        prompts.removeAll { $0 == .password(id) }
        let credentials = ServerCredentials(password: password)
        if let profile = profile(id), profile.savesPassword, let keychain {
            // A profile that came from another device through iCloud has no password here yet;
            // the backend reads it from this device's Keychain.
            do {
                try await keychain.save(credentials, for: id, includeBackgroundCopy: false)
            } catch {
                runtime[id, default: Runtime()].state = .failed(.credentialsUnavailable)
                return
            }
        } else {
            await sessionCredentials.set(credentials, for: id)
        }
        await connect(id, interactive: true)
    }

    func requestPassword(for id: ServerID) {
        enqueue(.password(id))
    }

    func requestOTP(for id: ServerID) {
        enqueue(.otp(id))
    }

    // MARK: Refresh

    func refreshSnapshot(_ id: ServerID) async {
        guard let backend = backends[id], runtime[id]?.state.isConnected == true else { return }
        guard let snapshot = try? await backend.systemSnapshot() else { return }
        runtime[id]?.snapshot = snapshot
        runtime[id]?.lastReached = .now
        await persistStatus(id)
    }

    func refreshUpdates(_ id: ServerID) async {
        guard let backend = backends[id], runtime[id]?.state.isConnected == true else { return }
        guard let updates = try? await backend.updates() else { return }
        runtime[id]?.pendingUpdates = updates.count
        await persistStatus(id)
        // Updates already seen in the app are not announced again by the background refresh.
        if profile(id)?.backgroundRefresh == true {
            await backgroundState?.update(id) {
                $0.health = HealthEventDetector.evaluate(previous: $0.health, snapshot: nil, updates: updates, containers: nil).state
            }
        }
    }

    /// All NAS in parallel; a slow NAS does not delay the others.
    func refreshOverview() async {
        let ids = profiles.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refreshSnapshot(id) }
            }
        }
    }

    func refreshAllUpdates() async {
        let ids = profiles.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refreshUpdates(id) }
            }
        }
    }

    private func persistStatus(_ id: ServerID) async {
        guard let statusCache, let profile = profile(id), let runtime = runtime[id] else { return }
        await statusCache.update(CachedServerStatus(
            serverID: id,
            name: profile.name,
            snapshot: runtime.snapshot,
            pendingUpdates: runtime.pendingUpdates,
            lastReached: runtime.lastReached,
            iconName: profile.iconName,
            colorName: profile.colorName
        ))
    }

    // MARK: Profiles

    func profile(_ id: ServerID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    func backend(for id: ServerID) -> (any ServerBackend)? {
        backends[id]
    }

    var updateSources: [UpdateSource] {
        profiles.compactMap { profile in
            guard let backend = backends[profile.id], runtime[profile.id]?.state.isConnected == true else { return nil }
            return UpdateSource(id: profile.id, name: profile.name, iconName: profile.iconName, colorName: profile.colorName, backend: backend,
                                shellHost: profile.backend == .proxmox ? profile.shellHost : nil)
        }
    }

    /// Connected NAS that offer their notification list.
    var inboxSources: [InboxSource] {
        profiles.compactMap { profile in
            guard let backend = backends[profile.id], let runtime = runtime[profile.id],
                  runtime.state.isConnected, runtime.capabilities.contains(.notifications) else { return nil }
            return InboxSource(id: profile.id, name: profile.name, iconName: profile.iconName, colorName: profile.colorName, backend: backend)
        }
    }

    var totalPendingUpdates: Int {
        runtime.values.compactMap(\.pendingUpdates).reduce(0, +)
    }

    /// Takes over a backend that the add-server flow already connected.
    func adopt(profile: ServerProfile, backend: any ServerBackend, credentials: ServerCredentials) async throws {
        guard !profiles.contains(where: { $0.id == profile.id }) else { return }
        var profile = profile
        profile.sortOrder = (profiles.map(\.sortOrder).max() ?? -1) + 1
        if profile.savesPassword {
            try await keychain?.save(credentials, for: profile.id, includeBackgroundCopy: false)
        } else {
            await sessionCredentials.set(credentials, for: profile.id)
        }
        try repository?.upsert(profile)
        profiles.append(profile)
        runtime[profile.id] = Runtime(state: .connected, capabilities: await backend.capabilities())
        attach(backend, for: profile.id)
        await refreshSnapshot(profile.id)
        await refreshUpdates(profile.id)
    }

    /// Logs out, then deletes the profile and every Keychain entry of this NAS (incl. background copy).
    func remove(_ id: ServerID) async {
        if let backend = backends[id] { await backend.disconnect() }
        eventTasks[id]?.cancel()
        eventTasks[id] = nil
        backends[id] = nil
        runtime[id] = nil
        prompts.removeAll { $0.serverID == id }
        profiles.removeAll { $0.id == id }
        try? repository?.delete(id)
        try? await keychain?.deleteAll(for: id)
        await sessionCredentials.remove(id)
        await statusCache?.remove(id)
        await backgroundState?.remove(id)
    }

    // MARK: Background refresh

    enum BackgroundRefreshError: LocalizedError {
        case passwordNotSaved

        var errorDescription: String? {
            String(localized: "Background refresh needs saved credentials that work without you: a saved password or an API token.")
        }
    }

    /// Turning it on stores a copy of the credentials that is readable while the device is locked
    /// (asks for Face ID once); turning it off deletes that copy immediately.
    func setBackgroundRefresh(_ id: ServerID, enabled: Bool) async throws {
        guard let keychain, let profile = profile(id) else { return }
        if enabled {
            guard profile.canSignInUnattended else { throw BackgroundRefreshError.passwordNotSaved }
            try await keychain.setBackgroundCopy(enabled: true, for: id)
            guard try await keychain.hasBackgroundCopy(for: id) else { throw BackgroundRefreshError.passwordNotSaved }
            await backgroundState?.update(id) { $0.pausedForLogin = false }
        } else {
            try await keychain.setBackgroundCopy(enabled: false, for: id)
            await backgroundState?.remove(id)
        }
        updateProfile(id) { $0.backgroundRefresh = enabled }
    }

    /// Runs the same detection as the background refresh, but over the connection the app already has,
    /// and posts the notifications right away. Lets the user see that the whole chain works.
    /// Returns the number of notifications posted, or `nil` when the NAS is not connected.
    func checkHealthNow(_ id: ServerID) async -> Int? {
        guard let backend = backends[id], let profile = profile(id), runtime[id]?.state.isConnected == true,
              let backgroundState else { return nil }
        let snapshot = try? await backend.systemSnapshot()
        let updates = try? await backend.updates()
        let capabilities = await backend.capabilities()
        let containers: [ContainerItem]? = capabilities.contains(.containers) ? try? await backend.containers() : nil
        let backups: [BackupTask]? = capabilities.contains(.backup) && profile.notifyBackupFailures ? try? await backend.backupTasks() : nil
        let threshold = NotificationPreferences.volumeThreshold
        let events = await backgroundState.update(id) { entry in
            let result = HealthEventDetector.evaluate(
                previous: entry.health, snapshot: snapshot, updates: updates, containers: containers,
                backups: backups, volumeFullThreshold: threshold
            )
            entry.health = result.state
            entry.lastRun = .now
            return result.events
        }
        return await BackgroundRefresher.notify(events, profile: profile)
    }

    func setNotifications(_ id: ServerID, _ matrix: NotificationMatrix) {
        updateProfile(id) { $0.notifications = matrix }
    }

    func setNotifyBackupFailures(_ id: ServerID, _ enabled: Bool) {
        updateProfile(id) { $0.notifyBackupFailures = enabled }
    }

    func rename(_ id: ServerID, to name: String, colorName: String, iconName: String) {
        updateProfile(id) {
            $0.name = name
            $0.colorName = colorName
            $0.iconName = iconName
        }
    }

    // MARK: Wake-on-LAN

    /// How long the app keeps trying to connect after sending the magic packet.
    static let wakeTimeout: Duration = .seconds(5 * 60)

    func setWakeOnLAN(_ id: ServerID, _ config: WakeOnLANConfig?) {
        updateProfile(id) { $0.wakeOnLAN = config }
    }

    /// Sends the magic packet, then tries to connect every 10 seconds for up to five minutes.
    func wake(_ id: ServerID) async {
        guard let profile = profile(id), let config = profile.wakeOnLAN else { return }
        runtime[id, default: Runtime()].wakeError = nil
        runtime[id, default: Runtime()].wakeBroadcastBlocked = false
        do {
            if isDemo, let mock = backends[id] as? MockBackend {
                Task { await mock.simulateWakeUp() }
            } else {
                let result = try await WakeOnLANSender.send(config, addresses: profile.addresses)
                runtime[id, default: Runtime()].wakeBroadcastBlocked = result.broadcastBlocked
            }
        } catch {
            runtime[id, default: Runtime()].wakeError = error.localizedDescription
            return
        }
        runtime[id, default: Runtime()].wakingSince = .now
        wakeTasks[id]?.cancel()
        wakeTasks[id] = Task { [weak self] in
            let deadline = ContinuousClock.now + Self.wakeTimeout
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(self?.isDemo == true ? 2 : 10))
                guard let self, !Task.isCancelled else { return }
                await self.connect(id)
                if self.runtime[id]?.state.isConnected == true { break }
            }
            guard let self, !Task.isCancelled else { return }
            if self.runtime[id]?.state.isConnected != true {
                self.runtime[id]?.wakeError = String(localized: "The server did not answer within five minutes. Check that Wake-on-LAN is enabled on it and that the iPhone is in the same network.")
            }
            self.runtime[id]?.wakingSince = nil
            self.wakeTasks[id] = nil
        }
    }

    func cancelWake(_ id: ServerID) {
        wakeTasks[id]?.cancel()
        wakeTasks[id] = nil
        runtime[id]?.wakingSince = nil
    }

    /// Fills in the MAC address the first time the NAS reports it; never overwrites what the user entered.
    private func learnWakeOnLAN(_ id: ServerID, from backend: any ServerBackend) async {
        guard profile(id)?.wakeOnLAN == nil, let config = await backend.wakeOnLANInfo() else { return }
        setWakeOnLAN(id, config)
    }

    private func updateProfile(_ id: ServerID, _ change: (inout ServerProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
        try? repository?.upsert(profiles[index])
    }

    // MARK: Backends

    private func makeBackend(for profile: ServerProfile) -> any ServerBackend {
        if isDemo, let spec = DemoData.spec(for: profile.id) {
            return MockBackend(spec: spec)
        }
        let credentials: any CredentialProvider
        if profile.savesPassword, let keychain {
            credentials = keychain
        } else {
            credentials = sessionCredentials
        }
        return BackendFactory.make(for: profile, credentials: credentials, deviceName: Self.deviceName, interactive: true)
    }

    private func attach(_ backend: any ServerBackend, for id: ServerID) {
        backends[id] = backend
        eventTasks[id]?.cancel()
        let stream = backend.events
        eventTasks[id] = Task { [weak self] in
            for await event in stream {
                self?.handle(event, for: id)
            }
        }
    }

    private func handle(_ event: BackendEvent, for id: ServerID) {
        switch event {
        case .state(let state):
            runtime[id, default: Runtime()].state = state
            if state == .connected { runtime[id]?.lastReached = .now }
            if case .failed(.passwordRequired) = state { enqueue(.password(id)) }
        case .addressReached(let addressID):
            if profile(id)?.lastReachedAddressID != addressID {
                updateProfile(id) { $0.lastReachedAddressID = addressID }
            }
        case .pinned(let spki):
            updateProfile(id) { $0.pinnedSPKI = spki }
        case .loggedIn:
            break
        case .sessionInterrupted:
            interruptedSessionServer = id
        }
    }

    // MARK: Tiles

    func tileModel(for profile: ServerProfile) -> ServerTileModel {
        let runtime = runtime[profile.id] ?? Runtime()
        let status: ServerTileModel.Status = switch runtime.state {
        case .connected, .reauthenticating: .online
        case .connecting: .connecting
        case .needsOTP: .attention(String(localized: "Code required"))
        case .rebooting: .attention(String(localized: "Restarting…"))
        case .disconnected: .offline(String(localized: "Not connected"))
        case .failed(let error): Self.tileStatus(for: error)
        }
        let snapshot = runtime.snapshot
        return ServerTileModel(
            id: profile.id,
            name: profile.name,
            iconName: profile.iconName,
            colorName: profile.colorName,
            status: status,
            model: snapshot?.model,
            cpuLoad: snapshot?.cpuLoad,
            memoryUsage: snapshot?.memoryUsage,
            volumeUsage: snapshot?.highestVolumeUsage,
            pendingUpdates: runtime.pendingUpdates,
            hasStorageProblem: snapshot?.hasStorageProblem ?? false,
            lastReached: runtime.lastReached
        )
    }

    private static func tileStatus(for error: BackendError) -> ServerTileModel.Status {
        switch error {
        case .unreachable, .timeout: .offline(String(localized: "Not reachable"))
        case .passwordRequired, .credentialsUnavailable, .openIDSignInRequired: .attention(String(localized: "Sign-in required"))
        case .certificateUntrusted: .attention(String(localized: "Confirm certificate"))
        case .fingerprintChanged: .attention(String(localized: "Certificate changed"))
        case .ipBlocked: .attention(String(localized: "IP blocked by NAS"))
        case .otpRequired, .otpInvalid: .attention(String(localized: "Code required"))
        case .invalidCredentials, .accountDisabled, .permissionDenied, .passwordExpired, .twoFactorSetupRequired:
            .attention(String(localized: "Sign-in failed"))
        default: .offline(String(localized: "Error"))
        }
    }
}
