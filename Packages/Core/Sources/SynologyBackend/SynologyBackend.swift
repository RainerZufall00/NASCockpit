import Foundation
import Domain
import Networking

/// `ServerBackend` adapter for Synology DSM 7.2+. Translates DSM responses into domain models;
/// nothing outside this module knows about DSM.
public actor SynologyBackend: ServerBackend {
    public nonisolated let serverID: ServerID
    public nonisolated let events: AsyncStream<BackendEvent>
    private let connection: DSMConnection
    private let taskPollInterval: Duration
    private let taskDeadline: Duration
    /// Hosts of the profile, to pick the network port the app talks to for Wake-on-LAN.
    private let profileHosts: [String]
    private var denied: Set<WriteAction> = []
    /// Log request phrasing the NAS accepted (see `DSMEndpoints.Logs.Variant`).
    private var logVariant: DSMEndpoints.Logs.Variant = .plain
    /// Hyper Backup destination checks, so polling the list does not contact every destination each time.
    private var targetChecks: [String: (online: Bool?, at: ContinuousClock.Instant)] = [:]
    private static let targetCheckLifetime: Duration = .seconds(60)

    public init(
        profile: ServerProfile,
        credentials: any CredentialProvider,
        deviceName: String,
        transport: (any HTTPTransport)? = nil
    ) {
        self.init(profile: profile, credentials: credentials, deviceName: deviceName, transport: transport, rebootPolicy: .standard)
    }

    init(
        profile: ServerProfile,
        credentials: any CredentialProvider,
        deviceName: String,
        transport: (any HTTPTransport)?,
        rebootPolicy: DSMConnection.RebootPolicy,
        taskPollInterval: Duration = .seconds(2),
        taskDeadline: Duration = .seconds(30 * 60)
    ) {
        serverID = profile.id
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        events = stream
        connection = DSMConnection(
            profile: profile,
            transport: transport ?? PinnedTransport(pinnedSPKI: profile.pinnedSPKI),
            credentials: credentials,
            deviceName: deviceName,
            events: continuation,
            rebootPolicy: rebootPolicy
        )
        self.taskPollInterval = taskPollInterval
        self.taskDeadline = taskDeadline
        profileHosts = profile.addresses.map(\.host)
    }

    public func capabilities() async -> Set<Capability> {
        await connection.capabilities
    }

    public func connect(otp: String?) async throws {
        try await connection.connect(otp: otp)
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    public func trustCertificate(_ certificate: CertificateInfo) async {
        await connection.trust(certificate)
    }

    public func systemSnapshot() async throws -> SystemSnapshot {
        do {
            let results = try await connection.compound([
                CompoundItem(DSMEndpoints.System.info),
                CompoundItem(DSMEndpoints.System.utilization),
                CompoundItem(DSMEndpoints.Storage.loadInfo),
            ])
            func result(_ api: String) -> CompoundResult? { results.first { $0.api == api } }
            return DSMMapping.snapshot(
                info: result("SYNO.Core.System")?.decode(SystemInfoDTO.self),
                utilization: result("SYNO.Core.System.Utilization")?.decode(UtilizationDTO.self),
                storage: result("SYNO.Storage.CGI.Storage")?.decode(StorageDTO.self)
            )
        } catch DSMError.unsupported {
            return try await snapshotWithoutCompound()
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    /// Fallback when `SYNO.Entry.Request` is not available.
    private func snapshotWithoutCompound() async throws -> SystemSnapshot {
        do {
            async let info = try? connection.call(DSMEndpoints.System.info)
            async let utilization = try? connection.call(DSMEndpoints.System.utilization)
            async let storage = try? connection.call(DSMEndpoints.Storage.loadInfo)
            return await DSMMapping.snapshot(info: info, utilization: utilization, storage: storage)
        }
    }

    public func installedPackages() async throws -> [PackageItem] {
        do {
            let installed = try await connection.call(DSMEndpoints.Packages.installed)
            let catalog = try? await connection.call(DSMEndpoints.Packages.serverCatalog)
            return DSMMapping.packages(installed, serverCatalog: catalog)
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    public func updates() async throws -> [UpdateItem] {
        do {
            let capabilities = await connection.capabilities
            var items: [UpdateItem] = []

            if capabilities.contains(.systemUpdate), let check = try? await connection.call(DSMEndpoints.Upgrade.check) {
                let installed = try? await connection.call(DSMEndpoints.System.info)
                if let item = DSMMapping.systemUpdate(check, installedVersion: installed?.firmwareVersion, serverID: serverID) {
                    items.append(item)
                }
            }

            if capabilities.contains(.packages) {
                let installed = try await connection.call(DSMEndpoints.Packages.installed)
                let catalog = try? await connection.call(DSMEndpoints.Packages.serverCatalog)
                let serverID = self.serverID
                items += DSMMapping.packages(installed, serverCatalog: catalog).compactMap { package in
                    guard let available = package.availableVersion else { return nil }
                    return UpdateItem(
                        serverID: serverID,
                        kind: .package(id: package.id),
                        name: package.name,
                        installedVersion: package.version,
                        availableVersion: available,
                        requiresReboot: false
                    )
                }
            }
            return items
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    public func refreshUpdateCatalog() async throws {
        guard await connection.capabilities.contains(.packages) else { return }
        try await read { _ = try await self.connection.call(DSMEndpoints.Packages.serverCatalog(forceReload: true)) }
    }

    // MARK: Virtual Machine Manager

    public func guests() async throws -> [VirtualGuest] {
        try await read { DSMMapping.guests(try await self.connection.call(DSMEndpoints.Virtualization.guests)) }
    }

    /// VMM has no reboot call: a reboot is a shutdown, waiting until the VM is off, then a power-on.
    public func perform(_ action: GuestAction, guest: VirtualGuest, progress: @escaping ProgressHandler) async throws {
        try await write(.guestControl) {
            switch action {
            case .start:
                _ = try await self.connection.call(DSMEndpoints.Virtualization.perform("poweron", guestID: guest.id))
            case .stop:
                _ = try await self.connection.call(DSMEndpoints.Virtualization.perform("poweroff", guestID: guest.id))
            case .shutdown:
                _ = try await self.connection.call(DSMEndpoints.Virtualization.perform("shutdown", guestID: guest.id))
            case .reboot:
                _ = try await self.connection.call(DSMEndpoints.Virtualization.perform("shutdown", guestID: guest.id))
                try await self.waitForGuest(guest.id, running: false)
                progress(0.5)
                _ = try await self.connection.call(DSMEndpoints.Virtualization.perform("poweron", guestID: guest.id))
            }
            progress(1)
        }
    }

    /// Polls the guest list until the VM reached the wanted state (reboot).
    private func waitForGuest(_ id: String, running: Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < taskDeadline {
            let guests = DSMMapping.guests(try await connection.call(DSMEndpoints.Virtualization.guests))
            if let guest = guests.first(where: { $0.id == id }), guest.status.isRunning == running { return }
            try await Task.sleep(for: taskPollInterval)
        }
        throw BackendError.timeout
    }

    /// VMM does not report guest addresses through its API.
    public func wakeOnLANInfo() async -> WakeOnLANConfig? {
        guard let info = try? await connection.call(DSMEndpoints.System.network) else { return nil }
        return DSMMapping.wakeOnLAN(info, hosts: profileHosts)
    }

    public func guestAddresses(_ guest: VirtualGuest) async throws -> [String] {
        []
    }

    public func logs(_ query: LogQuery) async throws -> LogPage {
        do {
            if query.source == .backup {
                return DSMMapping.backupLogPage(try await connection.call(DSMEndpoints.BackupLog.list(query)), query: query)
            }
            while true {
                do {
                    let variant = logVariant
                    var page = DSMMapping.logPage(try await connection.call(DSMEndpoints.Logs.list(query, variant: variant)), query: query)
                    // These variants send no keyword; search on the device instead.
                    if variant == .typeOnly || variant == .minimal, let keyword = query.keyword, !keyword.isEmpty {
                        page.entries = page.entries.filter {
                            $0.message.localizedCaseInsensitiveContains(keyword) || ($0.user?.localizedCaseInsensitiveContains(keyword) ?? false)
                        }
                    }
                    return page
                } catch DSMError.api(let code) {
                    // The NAS rejected this phrasing. Reads may be repeated: try the next one and keep
                    // using it for this session.
                    guard let next = DSMEndpoints.Logs.Variant(rawValue: logVariant.rawValue + 1) else { throw DSMError.api(code: code) }
                    logVariant = next
                }
            }
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    // MARK: Containers

    public func containers() async throws -> [ContainerItem] {
        do {
            let list = try await connection.call(DSMEndpoints.Docker.containers)
            let resources = try? await connection.call(DSMEndpoints.Docker.resources)
            return DSMMapping.containers(list, resources: resources)
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    public func composeProjects() async throws -> [ComposeProject] {
        do {
            let list = try await connection.call(DSMEndpoints.Docker.projects)
            let containers = (try? await connection.call(DSMEndpoints.Docker.containers)).map { DSMMapping.containers($0, resources: nil) } ?? []
            return DSMMapping.projects(list, containers: containers)
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    public func containerLogs(_ name: String, limit: Int) async throws -> [ContainerLogLine] {
        do {
            return DSMMapping.containerLogs(try await connection.call(DSMEndpoints.Docker.logs(name, limit: limit)))
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    // MARK: Writes

    public func deniedActions() async -> Set<WriteAction> {
        denied
    }

    public func setPackage(_ id: String, running: Bool) async throws {
        try await write(.packageControl) {
            _ = try await self.connection.call(running ? DSMEndpoints.PackageControl.start(id) : DSMEndpoints.PackageControl.stop(id))
        }
    }

    public func installPackageUpdate(_ id: String, progress: @escaping ProgressHandler) async throws {
        try await write(.packageUpdate) {
            var attempts: [String] = []
            let catalog = try? await self.connection.call(DSMEndpoints.Packages.serverCatalog)
            let entry = catalog?.packages.first(where: { $0.id == id })
            if let entry, let link = entry.link {
                do {
                    try await self.downloadAndUpgrade(id, url: link, checksum: entry.md5, size: entry.size, progress: progress)
                    return
                } catch let error as DSMError where !error.isSessionError && error != .permissionDenied && !error.isConnectivityError {
                    attempts.append(error.diagnostic)
                }
            } else {
                attempts.append(entry == nil ? "catalog: \(id) not listed" : "catalog: no download link")
            }
            do {
                try await self.upgradeByName(id, progress: progress)
            } catch let error as DSMError where !error.isSessionError && error != .permissionDenied && !error.isConnectivityError {
                attempts.append(error.diagnostic)
                throw BackendError.operationFailed(String(localized: "DSM did not accept the update. Details: \(attempts.joined(separator: "; "))"))
            }
        }
    }

    /// Like Package Center: download the new version (0 … 0.7 of the bar), then upgrade with that task.
    private func downloadAndUpgrade(_ id: String, url: String, checksum: String?, size: Int64?, progress: @escaping ProgressHandler) async throws {
        let (download, version) = try await callPerVersion("install") {
            DSMEndpoints.PackageInstallation.download(id, url: url, checksum: checksum, size: size, version: $0)
        }
        guard let downloadTask = download.taskID else {
            throw BackendError.operationFailed(String(localized: "The NAS did not start downloading the update."))
        }
        try await poll(progress: { value in progress(value.map { $0 * 0.7 }) }) {
            try await self.connection.call(DSMEndpoints.PackageInstallation.status(task: downloadTask, version: version))
        }
        progress(0.7)
        let (upgrade, upgradeVersion) = try await callPerVersion("upgrade(task_id)") {
            DSMEndpoints.PackageInstallation.upgrade(task: downloadTask, version: $0)
        }
        if let upgradeTask = upgrade.taskID, upgradeTask != downloadTask {
            try await poll(progress: { value in progress(value.map { 0.7 + $0 * 0.3 }) }) {
                try await self.connection.call(DSMEndpoints.PackageInstallation.status(task: upgradeTask, version: upgradeVersion))
            }
        }
        progress(1)
    }

    private func upgradeByName(_ id: String, progress: @escaping ProgressHandler) async throws {
        let (started, version) = try await callPerVersion("upgrade(name)") { DSMEndpoints.PackageInstallation.upgrade(id, version: $0) }
        // Without a task id DSM ran the upgrade synchronously.
        guard let taskID = started.taskID else {
            progress(1)
            return
        }
        try await poll(progress: progress) {
            try await self.connection.call(DSMEndpoints.PackageInstallation.status(task: taskID, version: version))
        }
    }

    /// Tries a Package Center call in each API version until one is not "method/version not available" (102–104).
    private func callPerVersion<T>(_ label: String, _ endpoint: (Int) -> DSMEndpoint<T>) async throws -> (T, Int) {
        var rejected: [String] = []
        for version in DSMEndpoints.PackageInstallation.versions {
            do {
                return (try await connection.call(endpoint(version)), version)
            } catch DSMError.unsupported(let detail) {
                rejected.append("v\(version) \(detail)")
            }
        }
        throw DSMError.unsupported("\(label): \(rejected.joined(separator: ", "))")
    }

    public func installSystemUpdate(progress: @escaping ProgressHandler) async throws {
        try await write(.systemUpdate) {
            // Download: 0 … 0.8 of the bar, installation + reboot: the rest (not measurable).
            if try await self.systemUpgradeStatus()?.isDownloaded != true {
                try await self.systemUpgradeStep("download") { _ = try await self.connection.call(DSMEndpoints.SystemUpgrade.download) }
                try await self.waitForSystemDownload { value in progress(value.map { $0 * 0.8 }) }
            }
            progress(0.8)
            try await self.systemUpgradeStep("install") { _ = try await self.connection.call(DSMEndpoints.SystemUpgrade.install) }
            progress(nil)
            try await self.connection.awaitReboot()
            progress(1)
        }
    }

    /// nil when this DSM has no `basic_status`; then only the download progress decides.
    private func systemUpgradeStatus() async throws -> UpgradeStatusDTO? {
        do {
            return try await connection.call(DSMEndpoints.SystemUpgrade.status)
        } catch let error as DSMError where !error.isSessionError && error != .permissionDenied && !error.isConnectivityError {
            return nil
        }
    }

    /// Done when DSM reports the update as ready to install or the download progress says finished.
    private func waitForSystemDownload(progress: @escaping ProgressHandler) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < taskDeadline {
            if try await systemUpgradeStatus()?.isDownloaded == true { return }
            let current = try await systemUpgradeStep("download progress") { try await self.connection.call(DSMEndpoints.SystemUpgrade.downloadProgress) }
            if current.hasFailed {
                throw BackendError.operationFailed(String(localized: "The NAS could not download the DSM update (\(current.errorCode ?? 0))."))
            }
            progress(current.fraction)
            if current.finished { return }
            try await Task.sleep(for: taskPollInterval)
        }
        throw BackendError.timeout
    }

    /// Names the step in a plain DSM error, so "error 101" says which call DSM rejected.
    private func systemUpgradeStep<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch DSMError.api(let code) {
            throw BackendError.operationFailed(String(localized: "DSM rejected the update (\(step), error \(String(code)))."))
        }
    }

    public func perform(_ action: ContainerAction, container name: String) async throws {
        try await write(.containerControl) {
            _ = try await self.connection.call(DSMEndpoints.Docker.control(action, name: name))
        }
    }

    public func perform(_ action: ProjectAction, project id: String) async throws {
        try await write(.projectControl) {
            _ = try await self.connection.call(DSMEndpoints.Docker.control(action, id: id))
        }
    }

    // MARK: Control Panel

    public func updateSettings() async throws -> UpdateSettings {
        try await read { DSMMapping.updateSettings(try await self.connection.call(DSMEndpoints.UpgradeSetting.get)) }
    }

    public func setUpdatePolicy(_ policy: UpdatePolicy) async throws {
        try await write(.updateSettings) {
            _ = try await self.connection.call(DSMEndpoints.UpgradeSetting.set(policy))
        }
    }

    public func users() async throws -> [NASUser] {
        try await read { DSMMapping.users(try await self.connection.call(DSMEndpoints.User.list)) }
    }

    public func setUser(_ name: String, disabled: Bool) async throws {
        // Never lock out the account this app signs in with.
        if disabled, name.caseInsensitiveCompare(await connection.username) == .orderedSame {
            throw BackendError.operationFailed(String(localized: "The app is signed in with this account. Disable it in DSM instead."))
        }
        try await write(.userControl) {
            _ = try await self.connection.call(DSMEndpoints.User.set(name, disabled: disabled))
        }
    }

    public func terminalSettings() async throws -> TerminalSettings {
        try await read {
            let dto = try await self.connection.call(DSMEndpoints.Terminal.get)
            return TerminalSettings(sshEnabled: dto.sshEnabled, sshPort: dto.sshPort)
        }
    }

    public func setSSH(enabled: Bool) async throws {
        try await write(.terminal) {
            let port = try? await self.connection.call(DSMEndpoints.Terminal.get).sshPort
            _ = try await self.connection.call(DSMEndpoints.Terminal.set(sshEnabled: enabled, port: port))
        }
    }

    public func activeConnections() async throws -> [ActiveConnection] {
        try await read { DSMMapping.connections(try await self.connection.call(DSMEndpoints.CurrentConnection.list)) }
    }

    public func perform(_ action: PowerAction, progress: @escaping ProgressHandler) async throws {
        try await write(.power) {
            _ = try await self.connection.call(DSMEndpoints.Power.perform(action))
            progress(nil)
            switch action {
            case .restart:
                try await self.connection.awaitReboot()
            case .shutDown:
                await self.connection.markShutDown()
            }
            progress(1)
        }
    }

    public func signedInUser() async -> String {
        await connection.username
    }

    // MARK: File Station

    public func sharedFolders() async throws -> [FileItem] {
        try await read { DSMMapping.files(try await self.connection.call(DSMEndpoints.FileStation.shares)) }
    }

    public func folderContents(_ path: String) async throws -> [FileItem] {
        try await read {
            var items: [FileItem] = []
            var offset = 0
            // Pages of 1000; stop at 10 000 entries, a phone list is not useful beyond that.
            while offset < 10_000 {
                let page = try await self.connection.call(DSMEndpoints.FileStation.list(path, offset: offset))
                items += DSMMapping.files(page)
                offset += page.entries.count
                guard !page.entries.isEmpty, offset < (page.total ?? 0) else { break }
            }
            return FileItem.sorted(items)
        }
    }

    public func transfer(_ path: String, to destination: String, mode: TransferMode, progress: @escaping ProgressHandler) async throws {
        try await write(.fileTransfer) {
            let started = try await self.connection.call(DSMEndpoints.FileStation.start(path, to: destination, mode: mode))
            guard let taskID = started.taskID else {
                throw BackendError.invalidResponse
            }
            try await self.poll(progress: progress) {
                try await self.connection.call(DSMEndpoints.FileStation.status(task: taskID))
            }
        }
    }

    public func createFolder(named name: String, in folder: String) async throws {
        try await write(.createFolder) {
            _ = try await self.connection.call(DSMEndpoints.FileStation.createFolder(name, in: folder))
        }
    }

    public func delete(_ paths: [String], progress: @escaping ProgressHandler) async throws {
        try await write(.deleteFiles) {
            let started = try await self.connection.call(DSMEndpoints.FileStation.startDelete(paths))
            guard let taskID = started.taskID else {
                throw BackendError.invalidResponse
            }
            try await self.poll(progress: progress) {
                try await self.connection.call(DSMEndpoints.FileStation.deleteStatus(task: taskID))
            }
        }
    }

    // MARK: Notifications

    public func notifications() async throws -> [NASNotification] {
        try await read { DSMMapping.notifications(try await self.connection.call(DSMEndpoints.Notify.load)) }
    }

    // MARK: Hyper Backup

    public func backupTasks() async throws -> [BackupTask] {
        try await read {
            var tasks = DSMMapping.backupTasks(try await self.connection.call(DSMEndpoints.Backup.list))
            let unchecked = tasks.filter { $0.targetOnline == nil && !$0.activity.isBusy }.map(\.id)
            let online = await self.targetOnline(unchecked, fresh: false)
            for index in tasks.indices {
                if tasks[index].activity.isBusy {
                    tasks[index].targetOnline = true
                } else if tasks[index].targetOnline == nil {
                    tasks[index].targetOnline = online[tasks[index].id] ?? nil
                }
            }
            return tasks
        }
    }

    public func perform(_ control: BackupControl, backup id: String) async throws {
        guard control == .start else {
            try await write(.backupControl) {
                _ = try await self.connection.call(DSMEndpoints.Backup.control(control, id: id))
            }
            return
        }
        let before = try? await read { DSMMapping.backupTasks(try await self.connection.call(DSMEndpoints.Backup.list)) }
            .first { $0.id == id }
        let name = before?.name ?? String(localized: "Task \(id)")
        if await targetOnline([id], fresh: true)[id] == false {
            throw BackendError.backupTargetOffline(task: name)
        }
        do {
            try await write(.backupControl) {
                _ = try await self.connection.call(DSMEndpoints.Backup.start(id))
            }
        } catch let error as BackendError where error != .actionNotPermitted && error != .cancelled {
            // DSM's codes for this are not documented; the destination check gives a clearer reason.
            if await targetOnline([id], fresh: true)[id] == false { throw BackendError.backupTargetOffline(task: name) }
            throw error
        }
        try await confirmBackupStarted(id, name: name, before: before)
    }

    /// DSM accepts the start even when the run ends right away (destination gone, locked, full).
    /// Watches the task briefly: running → fine; a new failed result or an offline destination → error.
    /// No clear answer within the window (queued behind another task) counts as started.
    private func confirmBackupStarted(_ id: String, name: String, before: BackupTask?) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: taskPollInterval)
            guard let task = try? await read({ DSMMapping.backupTasks(try await self.connection.call(DSMEndpoints.Backup.list)) })
                .first(where: { $0.id == id }) else { continue }
            if task.activity.isBusy { return }
            if task.isTargetOffline {
                targetChecks[id] = (false, .now)
                throw BackendError.backupTargetOffline(task: name)
            }
            let newRun = task.lastBackup != before?.lastBackup || task.lastResult != before?.lastResult
            if newRun, task.lastResult == .failed || task.lastResult == .cancelled {
                if await targetOnline([id], fresh: true)[id] == false { throw BackendError.backupTargetOffline(task: name) }
                throw BackendError.backupDidNotStart(task: name)
            }
        }
    }

    /// Asks Hyper Backup whether each destination answers, in parallel. Errors count as "unknown".
    private func targetOnline(_ ids: [String], fresh: Bool) async -> [String: Bool?] {
        var result: [String: Bool?] = [:]
        var pending: [String] = []
        for id in ids {
            if !fresh, let check = targetChecks[id], ContinuousClock.now - check.at < Self.targetCheckLifetime {
                result[id] = check.online
            } else {
                pending.append(id)
            }
        }
        guard !pending.isEmpty else { return result }
        let connection = connection
        let checked = await withTaskGroup(of: (String, Bool?).self) { group in
            for id in pending {
                group.addTask {
                    let status = try? await connection.call(DSMEndpoints.Backup.status(id))
                    return (id, status?.targetOnline)
                }
            }
            var checked: [(String, Bool?)] = []
            for await entry in group { checked.append(entry) }
            return checked
        }
        for (id, online) in checked {
            targetChecks[id] = (online, .now)
            result[id] = online
        }
        return result
    }

    // MARK: Snapshot Replication

    public func shareSnapshots() async throws -> [ShareSnapshots] {
        try await read {
            let shares = DSMMapping.files(try await self.connection.call(DSMEndpoints.FileStation.shares))
            var result: [ShareSnapshots] = []
            for share in shares where share.isDirectory {
                // Shares on volumes without snapshot support answer with an error: leave them out.
                guard let dto = try? await self.connection.call(DSMEndpoints.Snapshot.list(share: share.name)) else { continue }
                result.append(DSMMapping.snapshots(dto, share: share.name))
            }
            return result
        }
    }

    public func takeSnapshot(of share: String, description: String) async throws {
        try await write(.snapshot) {
            _ = try await self.connection.call(DSMEndpoints.Snapshot.create(share: share, description: description))
        }
    }

    public func replicationPlans() async throws -> [ReplicationPlan] {
        try await read { DSMMapping.replicationPlans(try await self.connection.call(DSMEndpoints.Replication.list)) }
    }

    public func syncReplication(_ planID: String) async throws {
        try await write(.replicationSync) {
            // DSM wants the plan's encryption setting repeated in the sync request.
            let plans = try await self.connection.call(DSMEndpoints.Replication.list)
            let encrypted = plans.plans.first { $0.id == planID }?.sendEncrypted ?? false
            _ = try await self.connection.call(DSMEndpoints.Replication.sync(planID: planID, sendEncrypted: encrypted))
        }
    }

    // MARK: Security Advisor

    public func securityReport() async throws -> SecurityScanReport {
        try await read {
            let status = try await self.connection.call(DSMEndpoints.SecurityScan.status)
            // The rule list is optional: without it the counts per category are still right.
            var rules: SecurityRulesDTO?
            if status.lastScanTime != nil {
                rules = try? await self.connection.call(DSMEndpoints.SecurityScan.rules)
            }
            return DSMMapping.securityReport(status, rules: rules)
        }
    }

    public func startSecurityScan() async throws {
        try await write(.securityScan) {
            do {
                _ = try await self.connection.call(DSMEndpoints.SecurityScan.start)
            } catch DSMError.unsupported {
                // Method name differs between DSM releases (see DSMSecurityEndpoints.swift).
                _ = try await self.connection.call(DSMEndpoints.SecurityScan.specificStart)
            }
        }
    }

    private func read<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    /// Maps errors and remembers 105 so the UI can hide the action for this NAS.
    private func write(_ action: WriteAction, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch DSMError.permissionDenied {
            denied.insert(action)
            throw BackendError.actionNotPermitted
        } catch {
            throw DSMError.backendError(from: error)
        }
    }

    /// Polls a NAS task until it reports finished or failed. Status reads may be retried normally.
    private func poll(progress: @escaping ProgressHandler, status: () async throws -> TaskStatusDTO) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < taskDeadline {
            let current = try await status()
            if current.hasFailed {
                throw BackendError.operationFailed(String(localized: "The NAS reported that the task failed (\(current.errorCode ?? 0))."))
            }
            progress(current.fraction)
            if current.finished { return }
            try await Task.sleep(for: taskPollInterval)
        }
        throw BackendError.timeout
    }
}
