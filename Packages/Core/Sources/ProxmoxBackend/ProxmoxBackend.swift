import Foundation
import Domain
import Networking

/// `ServerBackend` adapter for Proxmox VE 8. Translates the REST API into domain models;
/// nothing outside this module knows about Proxmox.
///
/// Sign-in: password (+ TOTP), API token, or OpenID Connect through the app's browser. Host updates
/// are listed and refreshed (`apt update`), but installing them is not offered by the Proxmox API.
public actor ProxmoxBackend: ServerBackend {
    public nonisolated let serverID: ServerID
    public nonisolated let events: AsyncStream<BackendEvent>
    private let connection: PVEConnection
    private var denied: Set<WriteAction> = [.packageUpdate, .systemUpdate]

    public init(
        profile: ServerProfile,
        credentials: any CredentialProvider,
        deviceName: String,
        openID: (any OpenIDAuthorizer)? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.init(profile: profile, credentials: credentials, deviceName: deviceName, openID: openID, transport: transport, policy: .standard)
    }

    init(
        profile: ServerProfile,
        credentials: any CredentialProvider,
        deviceName: String,
        openID: (any OpenIDAuthorizer)?,
        transport: (any HTTPTransport)?,
        policy: PVEConnection.Policy
    ) {
        serverID = profile.id
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        events = stream
        connection = PVEConnection(
            profile: profile,
            transport: transport ?? PinnedTransport(pinnedSPKI: profile.pinnedSPKI, trustedName: profile.trustedCertificateName),
            credentials: credentials,
            deviceName: deviceName,
            openID: openID,
            events: continuation,
            policy: policy
        )
    }

    /// Everything a Proxmox host offers in this app. Fixed: the API has no feature catalog.
    public static let capabilitySet: Set<Capability> = [.dashboard, .vms, .guestSnapshots, .backup, .backupLogs, .logs, .settings, .power]

    public func capabilities() async -> Set<Capability> {
        await connection.state.isConnected ? Self.capabilitySet : []
    }

    /// Lets the next `connect` open the browser for an OpenID sign-in (only for user-driven connects).
    public func setInteractiveSignIn(_ allowed: Bool) async {
        await connection.setInteractiveSignIn(allowed)
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

    /// Realms the host offers, without signing in (add-server flow: pick the OpenID realm).
    public func availableRealms() async throws -> [(realm: String, type: String, comment: String?)] {
        do {
            return try await connection.realms().map { ($0.realm, $0.type ?? "", $0.comment) }
        } catch {
            throw PVEError.backendError(from: error)
        }
    }

    /// Creates an API token for the signed-in user so later sign-ins need no browser, and switches this
    /// connection to it. Returns the full token ID and the secret (shown by Proxmox only once); the
    /// caller stores the secret as the profile's credential.
    public func createAPIToken(name: String) async throws -> (tokenID: String, secret: String) {
        do {
            let token = try await connection.createAPIToken(name: name)
            await connection.useAPIToken(token.tokenID)
            return token
        } catch {
            throw PVEError.backendError(from: error)
        }
    }

    // MARK: Dashboard

    public func systemSnapshot() async throws -> SystemSnapshot {
        try await read {
            let node = try await self.connection.node()
            async let status = try? self.connection.call(PVEEndpoints.Node.status(node))
            async let storages = try? self.connection.call(PVEEndpoints.Node.storage(node))
            async let disks = try? self.connection.call(PVEEndpoints.Node.disks(node))
            async let rrd = try? self.connection.call(PVEEndpoints.Node.rrd(node))
            async let version = try? self.connection.call(PVEEndpoints.version)
            let resolved = await (status, storages, disks, rrd, version)
            guard resolved.0 != nil else { throw PVEError.auth(.invalidResponse) }
            return PVEMapping.snapshot(node: node, version: resolved.4, status: resolved.0, storages: resolved.1 ?? [], disks: resolved.2 ?? [], rrd: resolved.3 ?? [])
        }
    }

    // MARK: Updates (host packages)

    public func installedPackages() async throws -> [PackageItem] {
        throw BackendError.notSupported
    }

    public func updates() async throws -> [UpdateItem] {
        try await read {
            let node = try await self.connection.node()
            return PVEMapping.updates(try await self.connection.call(PVEEndpoints.Apt.updates(node)), serverID: self.serverID)
        }
    }

    /// `apt update` on the host, then waits for it to finish.
    public func refreshUpdateCatalog() async throws {
        try await write(.refreshCatalog) {
            let node = try await self.connection.node()
            let upid = try await self.connection.call(PVEEndpoints.Apt.refresh(node))
            try await self.connection.waitForTask(upid) { _ in }
        }
    }

    public func installPackageUpdate(_ id: String, progress: @escaping ProgressHandler) async throws {
        throw BackendError.notSupported
    }

    public func installSystemUpdate(progress: @escaping ProgressHandler) async throws {
        throw BackendError.notSupported
    }

    // MARK: Logs

    public func logs(_ query: LogQuery) async throws -> LogPage {
        try await read {
            let node = try await self.connection.node()
            switch query.source {
            case .backup:
                // Newest first, like Proxmox's task list.
                let tasks = try await self.connection.call(PVEEndpoints.Node.tasks(node, type: "vzdump", limit: query.offset + query.limit))
                let page = Array(tasks.dropFirst(query.offset).prefix(query.limit))
                return PVEMapping.backupLog(page, query: query)
            case .system, .connection:
                let service = query.source == .connection ? "pvedaemon" : nil
                let result = try await self.connection.callWithTotal(
                    PVEEndpoints.Node.syslog(node, start: query.offset, limit: query.limit, since: query.from, until: query.to, service: service)
                )
                return PVEMapping.logPage(result.value, total: result.total, query: query, onlyAuthentication: query.source == .connection)
            }
        }
    }

    public func notifications() async throws -> [NASNotification] {
        throw BackendError.notSupported
    }

    // MARK: Containers (Docker) – not a Proxmox feature

    public func containers() async throws -> [ContainerItem] { throw BackendError.notSupported }
    public func composeProjects() async throws -> [ComposeProject] { throw BackendError.notSupported }
    public func containerLogs(_ name: String, limit: Int) async throws -> [ContainerLogLine] { throw BackendError.notSupported }
    public func perform(_ action: ContainerAction, container name: String) async throws { throw BackendError.notSupported }
    public func perform(_ action: ProjectAction, project id: String) async throws { throw BackendError.notSupported }

    // MARK: Virtual machines and containers

    public func guests() async throws -> [VirtualGuest] {
        try await read { PVEMapping.guests(try await self.connection.call(PVEEndpoints.Cluster.guests)) }
    }

    public func perform(_ action: GuestAction, guest: VirtualGuest, progress: @escaping ProgressHandler) async throws {
        try await write(.guestControl) {
            let upid = try await self.connection.call(PVEEndpoints.Guest.action(guest, action))
            try await self.connection.waitForTask(upid, progress: progress)
            progress(1)
        }
    }

    // MARK: Snapshots

    public func snapshots(of guest: VirtualGuest) async throws -> [GuestSnapshot] {
        try await read { PVEMapping.snapshots(try await self.connection.call(PVEEndpoints.Guest.snapshots(guest))) }
    }

    public func createSnapshot(of guest: VirtualGuest, name: String, description: String, includeMemory: Bool, progress: @escaping ProgressHandler) async throws {
        guard GuestSnapshotName.isValid(name) else { throw BackendError.operationFailed(String(localized: "Snapshot names start with a letter and use only letters, digits, “_” and “-” (2 to 40 characters).")) }
        try await snapshotTask(PVEEndpoints.Guest.createSnapshot(guest, name: name, description: description, includeMemory: includeMemory), progress: progress)
    }

    public func rollback(_ guest: VirtualGuest, to snapshot: String, progress: @escaping ProgressHandler) async throws {
        try await snapshotTask(PVEEndpoints.Guest.rollback(guest, snapshot: snapshot), progress: progress)
    }

    public func deleteSnapshot(_ snapshot: String, of guest: VirtualGuest, progress: @escaping ProgressHandler) async throws {
        try await snapshotTask(PVEEndpoints.Guest.deleteSnapshot(guest, snapshot: snapshot), progress: progress)
    }

    private func snapshotTask(_ endpoint: PVEEndpoint<PVEUPID>, progress: @escaping ProgressHandler) async throws {
        try await write(.guestSnapshot) {
            let upid = try await self.connection.call(endpoint)
            try await self.connection.waitForTask(upid, progress: progress)
            progress(1)
        }
    }

    public func hostNode() async -> String? {
        try? await connection.node()
    }

    public func guestAddresses(_ guest: VirtualGuest) async throws -> [String] {
        try await read {
            switch guest.kind {
            case .virtualMachine:
                // Without a running guest agent Proxmox answers 500 "No QEMU guest agent configured".
                let agent = try? await self.connection.call(PVEEndpoints.Guest.agentInterfaces(guest))
                return PVEMapping.addresses(agent: agent, container: nil)
            case .container:
                let interfaces = try? await self.connection.call(PVEEndpoints.Guest.containerInterfaces(guest))
                return PVEMapping.addresses(agent: nil, container: interfaces)
            }
        }
    }

    // MARK: Writes

    public func deniedActions() async -> Set<WriteAction> {
        denied
    }

    public func setPackage(_ id: String, running: Bool) async throws { throw BackendError.notSupported }

    // MARK: Control Panel (only power)

    public func updateSettings() async throws -> UpdateSettings { throw BackendError.notSupported }
    public func setUpdatePolicy(_ policy: UpdatePolicy) async throws { throw BackendError.notSupported }
    public func users() async throws -> [NASUser] { throw BackendError.notSupported }
    public func setUser(_ name: String, disabled: Bool) async throws { throw BackendError.notSupported }
    public func terminalSettings() async throws -> TerminalSettings { throw BackendError.notSupported }
    public func setSSH(enabled: Bool) async throws { throw BackendError.notSupported }
    public func activeConnections() async throws -> [ActiveConnection] { throw BackendError.notSupported }

    public func perform(_ action: PowerAction, progress: @escaping ProgressHandler) async throws {
        try await write(.power) {
            let node = try await self.connection.node()
            _ = try await self.connection.call(PVEEndpoints.Node.power(node, action))
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

    // MARK: File Station – not a Proxmox feature

    public func sharedFolders() async throws -> [FileItem] { throw BackendError.notSupported }
    public func folderContents(_ path: String) async throws -> [FileItem] { throw BackendError.notSupported }
    public func transfer(_ path: String, to destination: String, mode: TransferMode, progress: @escaping ProgressHandler) async throws { throw BackendError.notSupported }
    public func createFolder(named name: String, in folder: String) async throws { throw BackendError.notSupported }
    public func delete(_ paths: [String], progress: @escaping ProgressHandler) async throws { throw BackendError.notSupported }

    // MARK: Backups (vzdump jobs)

    public func backupTasks() async throws -> [BackupTask] {
        try await read {
            let jobs = try await self.connection.call(PVEEndpoints.Cluster.backupJobs)
            guard !jobs.isEmpty else { return [] }
            let nodes = try await self.onlineNodes()
            var tasks: [TaskListEntryDTO] = []
            for node in nodes {
                tasks += (try? await self.connection.call(PVEEndpoints.Node.tasks(node, type: "vzdump", limit: 50))) ?? []
            }
            var archives: [ContentDTO] = []
            let localNode = try await self.connection.node()
            for storage in Set(jobs.compactMap(\.storage)) {
                archives += (try? await self.connection.call(PVEEndpoints.Node.backupContent(localNode, storage: storage))) ?? []
            }
            return PVEMapping.backupTasks(jobs: jobs, tasks: tasks, archives: archives)
        }
    }

    /// Start: runs the job's settings through `vzdump` on its node (or this one). Cancel: stops the running
    /// vzdump task. Both return once Proxmox accepted the request.
    public func perform(_ control: BackupControl, backup id: String) async throws {
        try await write(.backupControl) {
            switch control {
            case .start:
                let job = try await self.connection.call(PVEEndpoints.Cluster.backupJob(id))
                let node: String
                if let jobNode = job.node { node = jobNode } else { node = try await self.connection.node() }
                _ = try await self.connection.call(PVEEndpoints.Node.vzdump(node, params: job.replayParameters))
            case .cancel:
                for node in try await self.onlineNodes() {
                    let tasks = (try? await self.connection.call(PVEEndpoints.Node.tasks(node, type: "vzdump", limit: 20))) ?? []
                    for task in tasks where task.isRunning {
                        if let upid = task.upid {
                            _ = try await self.connection.call(PVEEndpoints.Node.stopTask(node, upid: upid))
                        }
                    }
                }
            }
        }
    }

    private func onlineNodes() async throws -> [String] {
        let nodes = (try? await connection.call(PVEEndpoints.Cluster.nodes)) ?? []
        let online = nodes.filter { $0.status == "online" || $0.status == nil }.map(\.node)
        if online.isEmpty { return [try await connection.node()] }
        return online
    }

    // MARK: Snapshot Replication – not a Proxmox feature

    public func shareSnapshots() async throws -> [ShareSnapshots] { throw BackendError.notSupported }
    public func takeSnapshot(of share: String, description: String) async throws { throw BackendError.notSupported }
    public func replicationPlans() async throws -> [ReplicationPlan] { throw BackendError.notSupported }
    public func syncReplication(_ planID: String) async throws { throw BackendError.notSupported }

    // MARK: Helpers

    private func read<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw PVEError.backendError(from: error)
        }
    }

    /// Maps errors and remembers 403 so the UI can hide the action for this host.
    private func write(_ action: WriteAction, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch PVEError.permissionDenied {
            denied.insert(action)
            throw BackendError.actionNotPermitted
        } catch {
            throw PVEError.backendError(from: error)
        }
    }
}
