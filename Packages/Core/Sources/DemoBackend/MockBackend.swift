import Foundation
import Domain

/// Fulfils `ServerBackend` with sample data. Powers demo mode, SwiftUI previews and
/// App Store screenshots without a real NAS. Never touches the network.
public actor MockBackend: ServerBackend {
    public nonisolated let serverID: ServerID
    public nonisolated let events: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation
    private let spec: DemoServerSpec
    private let latency: Duration
    private var isConnected: Bool
    /// Starts as `spec.isOffline`; a simulated Wake-on-LAN brings the server up.
    private var isOffline: Bool
    /// Scales the simulated duration of long-running actions (0 in tests).
    private let actionDuration: Double

    // Mutable demo state, changed by write actions.
    private var packages: [PackageItem]
    private var osVersion: String
    private var systemUpdate: String?
    private var containerList: [ContainerItem]
    private var projectList: [ComposeProject]
    private var guestList: [VirtualGuest]
    private var guestSnapshots: [String: [GuestSnapshot]] = DemoData.guestSnapshots()
    private var updatePolicy: UpdatePolicy = .importantOnly
    private var userList: [NASUser] = DemoData.users
    private var sshEnabled = false
    private var tree: [String: [FileItem]] = DemoData.fileTree()
    private var backups: [BackupTask]
    private var snapshotShares: [ShareSnapshots] = DemoData.shareSnapshots()
    private var plans: [ReplicationPlan] = DemoData.replicationPlans()
    private var syncRuns: [String: Int] = [:]
    /// Bumped on every start / cancel so an older simulated run stops updating.
    private var backupRuns: [String: Int] = [:]

    public init(spec: DemoServerSpec, latency: Duration = .milliseconds(350), startConnected: Bool = false, actionDuration: Double = 1) {
        self.spec = spec
        self.latency = latency
        self.actionDuration = actionDuration
        packages = spec.packages
        osVersion = spec.osVersion
        systemUpdate = spec.systemUpdate
        containerList = spec.containers
        projectList = spec.projects
        guestList = spec.guests
        backups = spec.profile.backend == .proxmox ? DemoData.proxmoxBackupTasks() : DemoData.backupTasks()
        isConnected = startConnected && !spec.isOffline
        isOffline = spec.isOffline
        serverID = spec.profile.id
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        events = stream
        self.continuation = continuation
    }

    /// Convenience for previews.
    public static func preview(_ id: ServerID = DemoData.homeID) -> MockBackend {
        MockBackend(spec: DemoData.spec(for: id) ?? DemoData.servers[0], latency: .zero, startConnected: true)
    }

    public func capabilities() -> Set<Capability> {
        isConnected ? spec.capabilities : []
    }

    public func connect(otp: String?) async throws {
        continuation.yield(.state(.connecting))
        try await Task.sleep(for: latency)
        guard !isOffline else {
            continuation.yield(.state(.failed(.unreachable)))
            throw BackendError.unreachable
        }
        isConnected = true
        if let address = spec.profile.addresses.first {
            continuation.yield(.addressReached(address.id))
        }
        continuation.yield(.state(.connected))
    }

    public func disconnect() {
        isConnected = false
        continuation.yield(.state(.disconnected))
    }

    public func trustCertificate(_ certificate: CertificateInfo) {}

    public func systemSnapshot() async throws -> SystemSnapshot {
        try requireConnection()
        let t = Date.now.timeIntervalSince1970
        let seed = Double(spec.profile.sortOrder) * 1.7
        func wave(_ period: Double, _ amplitude: Double) -> Double { sin(t / period + seed) * amplitude }

        let cpu = clamp(spec.cpuBase + wave(6, 0.08) + wave(2.3, 0.04))
        let memory = clamp(spec.memoryBase + wave(40, 0.03))
        return SystemSnapshot(
            model: spec.model,
            osVersion: osVersion,
            uptime: spec.uptimeBase + t.truncatingRemainder(dividingBy: 86_400),
            temperature: 41 + wave(30, 2),
            temperatureWarning: false,
            cpuLoad: cpu,
            memoryUsage: memory,
            memoryTotalBytes: spec.memoryTotal,
            network: NetworkThroughput(
                rxBytesPerSecond: max(0, 2_400_000 + wave(5, 1_800_000)),
                txBytesPerSecond: max(0, 650_000 + wave(3.5, 500_000))
            ),
            diskReadBytesPerSecond: max(0, 8_000_000 + wave(4, 6_000_000)),
            diskWriteBytesPerSecond: max(0, 3_000_000 + wave(7, 2_500_000)),
            volumes: spec.volumes,
            disks: spec.disks.map { disk in
                var disk = disk
                disk.temperature = disk.temperature.map { $0 + wave(25, 1).rounded() }
                return disk
            },
            capturedAt: .now
        )
    }

    public func installedPackages() async throws -> [PackageItem] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return packages
    }

    public func updates() async throws -> [UpdateItem] {
        try requireConnection()
        try await Task.sleep(for: latency)
        var items: [UpdateItem] = []
        if let system = systemUpdate {
            items.append(UpdateItem(serverID: serverID, kind: .system, name: "DSM", installedVersion: osVersion, availableVersion: system, requiresReboot: true))
        }
        items += packages.compactMap { package in
            package.availableVersion.map {
                UpdateItem(serverID: serverID, kind: .package(id: package.id), name: package.name, installedVersion: package.version, availableVersion: $0,
                           requiresReboot: spec.profile.backend == .proxmox && package.name.contains("kernel"))
            }
        }
        return items
    }

    public func refreshUpdateCatalog() async throws {
        try requireConnection()
        try await simulate(seconds: 1.5)
    }

    // MARK: Virtual machines

    public func guests() async throws -> [VirtualGuest] {
        try requireConnection()
        guard spec.capabilities.contains(.vms) else { throw BackendError.notSupported }
        try await Task.sleep(for: latency)
        let t = Date.now.timeIntervalSince1970
        return guestList.map { guest in
            var guest = guest
            if guest.status.isRunning {
                guest.cpuLoad = guest.cpuLoad.map { clamp($0 + sin(t / 5 + Double(guest.vmid)) * 0.05) }
                guest.uptime = guest.uptime.map { $0 + t.truncatingRemainder(dividingBy: 3600) }
            }
            return guest
        }
    }

    public func perform(_ action: GuestAction, guest: VirtualGuest, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        guard let index = guestList.firstIndex(where: { $0.id == guest.id }) else { throw BackendError.notSupported }
        try await simulate(seconds: action == .start ? 2 : action == .reboot ? 4 : 3, steps: 6, progress: progress)
        switch action {
        case .start, .reboot:
            guestList[index].status = .running
            guestList[index].uptime = 5
            guestList[index].cpuLoad = 0.02
            guestList[index].memoryBytes = (guestList[index].maxMemoryBytes ?? 0) / 4
        case .shutdown, .stop:
            guestList[index].status = .stopped
            guestList[index].uptime = nil
            guestList[index].cpuLoad = nil
            guestList[index].memoryBytes = nil
        }
    }

    public func wakeOnLANInfo() async -> WakeOnLANConfig? {
        spec.profile.backend == .synology ? WakeOnLANConfig(mac: MACAddress("00:11:32:5A:7B:\(String(format: "%02X", spec.profile.sortOrder + 16))")!, broadcast: "192.168.1.255") : nil
    }

    /// Demo stand-in for the magic packet: the server answers again after a short "boot".
    public func simulateWakeUp() async {
        try? await Task.sleep(for: latency * 12)
        isOffline = false
    }

    public func hostNode() async -> String? {
        spec.profile.backend == .proxmox ? "pve" : nil
    }

    public func snapshots(of guest: VirtualGuest) async throws -> [GuestSnapshot] {
        try requireConnection()
        guard spec.capabilities.contains(.guestSnapshots) else { throw BackendError.notSupported }
        try await Task.sleep(for: latency)
        return (guestSnapshots[guest.id] ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public func createSnapshot(of guest: VirtualGuest, name: String, description: String, includeMemory: Bool, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        guard GuestSnapshotName.isValid(name) else { throw BackendError.operationFailed(String(localized: "Snapshot names start with a letter and use only letters, digits, “_” and “-” (2 to 40 characters).")) }
        if guestSnapshots[guest.id]?.contains(where: { $0.name == name }) == true {
            throw BackendError.operationFailed(String(localized: "A snapshot named “\(name)” already exists."))
        }
        try await simulate(seconds: includeMemory ? 4 : 2, steps: 5, progress: progress)
        let parent = guestSnapshots[guest.id]?.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }?.name
        guestSnapshots[guest.id, default: []].append(
            GuestSnapshot(name: name, description: description, date: .now, includesMemory: includeMemory && guest.kind == .virtualMachine, parent: parent)
        )
    }

    public func rollback(_ guest: VirtualGuest, to snapshot: String, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        guard let snap = guestSnapshots[guest.id]?.first(where: { $0.name == snapshot }),
              let index = guestList.firstIndex(where: { $0.id == guest.id }) else { throw BackendError.notSupported }
        try await simulate(seconds: 3, steps: 5, progress: progress)
        // Like Proxmox: a snapshot with RAM resumes the VM, otherwise the guest ends up stopped.
        if !snap.includesMemory {
            guestList[index].status = .stopped
            guestList[index].uptime = nil
            guestList[index].cpuLoad = nil
            guestList[index].memoryBytes = nil
        }
    }

    public func deleteSnapshot(_ snapshot: String, of guest: VirtualGuest, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        try await simulate(seconds: 1.5, steps: 3, progress: progress)
        guestSnapshots[guest.id]?.removeAll { $0.name == snapshot }
    }

    public func guestAddresses(_ guest: VirtualGuest) async throws -> [String] {
        try requireConnection()
        try await Task.sleep(for: latency)
        guard guest.status.isRunning, spec.profile.backend == .proxmox else { return [] }
        return ["192.168.1.\(guest.vmid)", "fd00::\(String(guest.vmid, radix: 16))"]
    }

    public func logs(_ query: LogQuery) async throws -> LogPage {
        try requireConnection()
        try await Task.sleep(for: latency)
        let all: [LogEntry] = switch query.source {
        case .system: Self.generatedLogs().filter { $0.category != "Connection" }
        case .connection: Self.generatedLogs().filter { $0.category == "Connection" }
        case .backup: Self.generatedBackupLogs(tasks: backups)
        }
        let keyword = query.keyword?.lowercased()
        let filtered = all.filter { entry in
            query.matches(entry) && (keyword.map { entry.message.lowercased().contains($0) } ?? true)
        }
        let page = Array(filtered.dropFirst(query.offset).prefix(query.limit))
        let next = query.offset + page.count
        return LogPage(entries: page, total: filtered.count, nextOffset: next < filtered.count ? next : nil)
    }

    // MARK: Containers

    public func containers() async throws -> [ContainerItem] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return containerList
    }

    public func composeProjects() async throws -> [ComposeProject] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return projectList.map { project in
            var project = project
            let members = containerList.filter { project.containerNames.contains($0.name) }
            let running = members.filter(\.status.isRunning).count
            project.status = running == members.count ? .running : running == 0 ? .stopped : .partial
            return project
        }
    }

    public func containerLogs(_ name: String, limit: Int) async throws -> [ContainerLogLine] {
        try requireConnection()
        try await Task.sleep(for: latency)
        guard let container = containerList.first(where: { $0.name == name }) else { return [] }
        let now = Date.now
        var lines = (0..<min(limit, 80)).map { index in
            ContainerLogLine(
                id: index,
                date: now.addingTimeInterval(-Double(index) * 37),
                stream: index % 9 == 4 ? "stderr" : "stdout",
                text: DemoData.containerLogMessages[index % DemoData.containerLogMessages.count]
            )
        }
        if container.hasFailed {
            lines.insert(ContainerLogLine(id: -1, date: now, stream: "stderr", text: "Error: serial port /dev/ttyUSB0 not found, exiting with code \(container.exitCode ?? 1)"), at: 0)
        }
        return lines
    }

    // MARK: Writes

    public func deniedActions() -> Set<WriteAction> {
        // Proxmox has no API for installing host updates; the app only lists them.
        spec.profile.backend == .proxmox ? [.packageUpdate] : []
    }

    public func setPackage(_ id: String, running: Bool) async throws {
        try requireConnection()
        guard let index = packages.firstIndex(where: { $0.id == id }) else { throw BackendError.notSupported }
        try await simulate(seconds: 1.2)
        packages[index].status = running ? .running : .stopped
    }

    public func installPackageUpdate(_ id: String, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        guard let index = packages.firstIndex(where: { $0.id == id }), let available = packages[index].availableVersion else {
            throw BackendError.notSupported
        }
        try await simulate(seconds: 3, steps: 12, progress: progress)
        packages[index].version = available
        packages[index].availableVersion = nil
    }

    public func installSystemUpdate(progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        guard let available = systemUpdate else { throw BackendError.notSupported }
        try await simulate(seconds: 4, steps: 16) { value in progress(value.map { $0 * 0.8 }) }
        progress(nil)
        isConnected = false
        continuation.yield(.state(.rebooting))
        try await simulate(seconds: 8)
        osVersion = available
        systemUpdate = nil
        isConnected = true
        continuation.yield(.state(.connected))
        progress(1)
    }

    public func perform(_ action: ContainerAction, container name: String) async throws {
        try requireConnection()
        guard containerList.contains(where: { $0.name == name }) else { throw BackendError.notSupported }
        try await simulate(seconds: action == .restart ? 2 : 1.2)
        setContainers([name], running: action != .stop)
    }

    public func perform(_ action: ProjectAction, project id: String) async throws {
        try requireConnection()
        guard let project = projectList.first(where: { $0.id == id }) else { throw BackendError.notSupported }
        try await simulate(seconds: action == .rebuild ? 5 : 2)
        setContainers(project.containerNames, running: action != .stop)
    }

    // MARK: Control Panel

    public func updateSettings() async throws -> UpdateSettings {
        try requireConnection()
        try await Task.sleep(for: latency)
        return UpdateSettings(policy: updatePolicy, schedule: "Sun 03:00")
    }

    public func setUpdatePolicy(_ policy: UpdatePolicy) async throws {
        try requireConnection()
        try await simulate(seconds: 0.6)
        updatePolicy = policy
    }

    public func users() async throws -> [NASUser] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return userList
    }

    public func setUser(_ name: String, disabled: Bool) async throws {
        try requireConnection()
        if disabled, name == spec.profile.username {
            throw BackendError.operationFailed(String(localized: "The app is signed in with this account. Disable it in DSM instead."))
        }
        guard let index = userList.firstIndex(where: { $0.name == name }) else { throw BackendError.notSupported }
        try await simulate(seconds: 0.8)
        userList[index].isDisabled = disabled
    }

    public func terminalSettings() async throws -> TerminalSettings {
        try requireConnection()
        try await Task.sleep(for: latency)
        return TerminalSettings(sshEnabled: sshEnabled, sshPort: 22)
    }

    public func setSSH(enabled: Bool) async throws {
        try requireConnection()
        try await simulate(seconds: 0.8)
        sshEnabled = enabled
    }

    public func activeConnections() async throws -> [ActiveConnection] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return DemoData.connections()
    }

    public func perform(_ action: PowerAction, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        try await simulate(seconds: 1)
        progress(nil)
        isConnected = false
        switch action {
        case .restart:
            continuation.yield(.state(.rebooting))
            try await simulate(seconds: 8)
            isConnected = true
            continuation.yield(.state(.connected))
        case .shutDown:
            continuation.yield(.state(.disconnected))
        }
        progress(1)
    }

    public func signedInUser() -> String {
        spec.profile.username
    }

    // MARK: File Station

    public func sharedFolders() async throws -> [FileItem] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return FileItem.sorted(tree["/"] ?? [])
    }

    public func folderContents(_ path: String) async throws -> [FileItem] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return FileItem.sorted(tree[path] ?? [])
    }

    public func transfer(_ path: String, to destination: String, mode: TransferMode, progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        let parent = FileItem.parent(of: path)
        guard let item = tree[parent]?.first(where: { $0.path == path }) else { throw BackendError.notSupported }
        guard FileValidation.canTransfer(item, to: destination, mode: mode) else { throw BackendError.notSupported }
        try await simulate(seconds: item.isDirectory ? 3 : 1.5, steps: 10, progress: progress)
        // Same name in the target is skipped, like DSM with overwrite=false.
        guard !(tree[destination] ?? []).contains(where: { $0.name == item.name }) else { return }
        let newPath = FileItem.join(destination, item.name)
        copySubtree(from: item, to: newPath)
        if mode == .move { removeSubtree(item) }
    }

    public func createFolder(named name: String, in folder: String) async throws {
        try requireConnection()
        guard FileValidation.isValidName(name) else { throw BackendError.notSupported }
        try await simulate(seconds: 0.4)
        guard !(tree[folder] ?? []).contains(where: { $0.name == name }) else { return }
        let path = FileItem.join(folder, name)
        tree[folder, default: []].append(FileItem(path: path, name: name, isDirectory: true, modified: .now))
        tree[path] = []
    }

    public func delete(_ paths: [String], progress: @escaping ProgressHandler) async throws {
        try requireConnection()
        let items = paths.compactMap { path in tree[FileItem.parent(of: path)]?.first { $0.path == path } }
        guard !items.isEmpty else { throw BackendError.notSupported }
        try await simulate(seconds: items.contains(where: \.isDirectory) ? 2 : 0.8, steps: 8, progress: progress)
        for item in items { removeSubtree(item) }
    }

    // MARK: Hyper Backup

    public func notifications() async throws -> [NASNotification] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return DemoData.notifications(for: serverID)
    }

    public func backupTasks() async throws -> [BackupTask] {
        try requireConnection()
        try await Task.sleep(for: latency)
        // Let the task that is already running in the sample data move on.
        for task in backups where backupRuns[task.id] == nil {
            if case .running(let progress) = task.activity {
                backupRuns[task.id] = 1
                Task { await self.runBackup(task.id, run: 1, from: progress ?? 0, stepSeconds: 3) }
            }
        }
        return backups
    }

    public func perform(_ control: BackupControl, backup id: String) async throws {
        try requireConnection()
        guard let index = backups.firstIndex(where: { $0.id == id }) else { throw BackendError.notSupported }
        try await simulate(seconds: 0.5)
        let run = backupRuns[id, default: 0] + 1
        backupRuns[id] = run
        switch control {
        case .start:
            guard !backups[index].activity.isBusy else { return }
            if backups[index].isTargetOffline { throw BackendError.backupTargetOffline(task: backups[index].name) }
            backups[index].activity = .running(progress: 0)
            Task { await self.runBackup(id, run: run) }
        case .cancel:
            guard backups[index].activity.isBusy else { return }
            backups[index].activity = .idle
            backups[index].lastResult = .cancelled
            backups[index].lastBackup = .now
        }
    }

    /// Simulated run on the "NAS": progress over a few seconds, then success.
    private func runBackup(_ id: String, run: Int, from start: Double = 0, stepSeconds: Double = 0.6) async {
        for step in min(Int(start * 20) + 1, 20)...20 {
            try? await Task.sleep(for: .seconds(stepSeconds * actionDuration))
            guard backupRuns[id] == run, let index = backups.firstIndex(where: { $0.id == id }) else { return }
            if step == 20 {
                backups[index].activity = .idle
                backups[index].lastResult = .success
                backups[index].lastBackup = .now
            } else {
                backups[index].activity = .running(progress: Double(step) / 20)
            }
        }
    }

    // MARK: Snapshot Replication

    public func shareSnapshots() async throws -> [ShareSnapshots] {
        try requireConnection()
        try await Task.sleep(for: latency)
        return snapshotShares
    }

    public func takeSnapshot(of share: String, description: String) async throws {
        try requireConnection()
        guard let index = snapshotShares.firstIndex(where: { $0.share == share }) else { throw BackendError.notSupported }
        try await simulate(seconds: 1.2)
        let date = Date.now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd-HH.mm.ss"
        let name = String(format: "GMT%+03d-", TimeZone.current.secondsFromGMT(for: date) / 3600) + formatter.string(from: date)
        let item = SnapshotItem(id: name, date: date, description: description.isEmpty ? nil : description)
        snapshotShares[index] = ShareSnapshots(share: share, snapshots: snapshotShares[index].snapshots + [item])
    }

    public func replicationPlans() async throws -> [ReplicationPlan] {
        try requireConnection()
        try await Task.sleep(for: latency)
        // Let the sync that is already running in the sample data move on.
        for plan in plans where plan.isSyncing && syncRuns[plan.id] == nil {
            syncRuns[plan.id] = 1
            Task { await self.runSync(plan.id, run: 1, from: plan.progress ?? 0, stepSeconds: 3) }
        }
        return plans
    }

    public func syncReplication(_ planID: String) async throws {
        try requireConnection()
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { throw BackendError.notSupported }
        guard plans[index].canSync else { throw BackendError.notSupported }
        try await simulate(seconds: 0.5)
        guard !plans[index].isSyncing else { return }
        let run = syncRuns[planID, default: 0] + 1
        syncRuns[planID] = run
        plans[index].isSyncing = true
        plans[index].progress = 0
        Task { await self.runSync(planID, run: run) }
    }

    /// Simulated replication: progress over a few seconds; the plan to the offline Backup NAS fails.
    private func runSync(_ id: String, run: Int, from start: Double = 0, stepSeconds: Double = 0.5) async {
        for step in min(Int(start * 20) + 1, 20)...20 {
            try? await Task.sleep(for: .seconds(stepSeconds * actionDuration))
            guard syncRuns[id] == run, let index = plans.firstIndex(where: { $0.id == id }) else { return }
            let fails = plans[index].partner == "backup-nas"
            if step == 20 || (fails && step == 3) {
                plans[index].isSyncing = false
                plans[index].progress = nil
                plans[index].lastSync = .now
                plans[index].lastSyncSucceeded = !fails
                if fails { plans[index].failedSyncCount += 1 }
                return
            }
            plans[index].progress = Double(step) / 20
        }
    }

    private func copySubtree(from item: FileItem, to newPath: String) {
        var copy = item
        copy.path = newPath
        tree[FileItem.parent(of: newPath), default: []].append(copy)
        guard item.isDirectory else { return }
        tree[newPath] = []
        for child in tree[item.path] ?? [] {
            copySubtree(from: child, to: FileItem.join(newPath, child.name))
        }
    }

    private func removeSubtree(_ item: FileItem) {
        tree[item.parentPath]?.removeAll { $0.path == item.path }
        for key in tree.keys where key == item.path || key.hasPrefix(item.path + "/") {
            tree[key] = nil
        }
    }

    private func setContainers(_ names: [String], running: Bool) {
        for index in containerList.indices where names.contains(containerList[index].name) {
            containerList[index].status = running ? .running : .exited
            containerList[index].exitCode = running ? nil : 0
            containerList[index].startedAt = running ? .now : containerList[index].startedAt
            containerList[index].cpuPercent = running ? 0.5 : nil
            containerList[index].memoryBytes = running ? containerList[index].memoryBytes ?? 50 * 1_048_576 : nil
        }
    }

    private func simulate(seconds: Double, steps: Int = 1, progress: ProgressHandler? = nil) async throws {
        let step = seconds * actionDuration / Double(steps)
        for index in 1...steps {
            try await Task.sleep(for: .seconds(step))
            progress?(Double(index) / Double(steps))
        }
    }

    private func requireConnection() throws {
        guard isConnected else { throw BackendError.notConnected }
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Hyper Backup log: one run per task per night for two weeks, newest first, matching each task's result.
    static func generatedBackupLogs(tasks: [BackupTask], now: Date = .now) -> [LogEntry] {
        var entries: [(Date, LogLevel, String, String)] = []
        for (taskIndex, task) in tasks.enumerated() {
            // Runs end at the task's "last backup" time, one per day before that.
            let lastEnd = task.lastBackup ?? now.addingTimeInterval(-Double(taskIndex) * 3_600 - 4 * 3_600)
            for day in 0..<14 {
                let end = lastEnd.addingTimeInterval(-Double(day) * 86_400)
                let start = end.addingTimeInterval(-Double(300 + taskIndex * 240))
                let latest = day == 0
                entries.append((start, .info, task.name, "Backup task started."))
                switch (latest ? task.lastResult : .success) ?? .success {
                case .success:
                    entries.append((end, .info, task.name, "Backup task finished successfully. [\(1200 + taskIndex * 310) files scanned] [\(4 + day) files changed]"))
                case .partial:
                    entries.append((end.addingTimeInterval(-30), .warning, task.name, "Incomplete file backup. (The file is in use.) [/volume1/photo/2025/IMG_0042.HEIC]"))
                    entries.append((end, .warning, task.name, "Backup task partially completed."))
                case .failed:
                    entries.append((end, .error, task.name, "Failed to connect to the backup destination. Please check the network connection."))
                    entries.append((end.addingTimeInterval(1), .error, task.name, "Backup task failed."))
                case .cancelled:
                    entries.append((end, .warning, task.name, "Backup task was cancelled."))
                }
                if day % 7 == 3 {
                    entries.append((end.addingTimeInterval(1_800), .info, task.name, "Backup integrity check is finished. No error was found."))
                }
            }
        }
        return entries
            .filter { $0.0 <= now }
            .sorted { $0.0 > $1.0 }
            .enumerated()
            .map { LogEntry(id: $0.offset, date: $0.element.0, level: $0.element.1, category: $0.element.2, user: "SYSTEM", message: $0.element.3) }
    }

    /// 600 entries, newest first, every ~7 minutes.
    static func generatedLogs(now: Date = .now) -> [LogEntry] {
        (0..<600).map { index in
            let template = DemoData.logMessages[index % DemoData.logMessages.count]
            return LogEntry(
                id: index,
                date: now.addingTimeInterval(-Double(index) * 420),
                level: template.0,
                category: template.1,
                user: template.2,
                message: template.3
            )
        }
    }
}
