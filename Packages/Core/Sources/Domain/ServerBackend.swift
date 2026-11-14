import Foundation

public struct LoginInfo: Sendable, Hashable {
    public var usedOTP: Bool
    public var hasDeviceToken: Bool
    public var isReauthentication: Bool

    public init(usedOTP: Bool, hasDeviceToken: Bool, isReauthentication: Bool) {
        self.usedOTP = usedOTP
        self.hasDeviceToken = hasDeviceToken
        self.isReauthentication = isReauthentication
    }
}

/// Things a backend reports on its own, independent of a specific call.
public enum BackendEvent: Sendable, Hashable {
    case state(ConnectionState)
    /// The address that answered with a matching certificate. Persist as "last reached".
    case addressReached(UUID)
    /// The user confirmed a certificate. Persist into the profile.
    case pinned(spki: String)
    case loggedIn(LoginInfo)
    /// DSM ended the session because of a duplicate login (error 107).
    case sessionInterrupted
}

/// The only thing views and view models talk to. Synology is the first adapter;
/// Proxmox and TrueNAS can be added later without touching the UI.
public protocol ServerBackend: Actor {
    nonisolated var serverID: ServerID { get }
    /// Single consumer stream (the ConnectionManager).
    nonisolated var events: AsyncStream<BackendEvent> { get }

    func capabilities() async -> Set<Capability>
    func connect(otp: String?) async throws
    func disconnect() async
    func trustCertificate(_ certificate: CertificateInfo) async

    func systemSnapshot() async throws -> SystemSnapshot
    func installedPackages() async throws -> [PackageItem]
    func updates() async throws -> [UpdateItem]
    /// Asks the server to refresh its list of available updates (DSM package catalog, Proxmox `apt update`).
    func refreshUpdateCatalog() async throws
    func logs(_ query: LogQuery) async throws -> LogPage

    /// The NAS's own notifications, newest first. Reading does not mark them as read on the NAS.
    func notifications() async throws -> [NASNotification]

    // MARK: Containers (read)

    func containers() async throws -> [ContainerItem]
    func composeProjects() async throws -> [ComposeProject]
    func containerLogs(_ name: String, limit: Int) async throws -> [ContainerLogLine]

    // MARK: Virtual machines and containers (Proxmox)

    /// All guests of the cluster the server belongs to.
    func guests() async throws -> [VirtualGuest]
    /// Returns once the server reports the task as finished.
    func perform(_ action: GuestAction, guest: VirtualGuest, progress: @escaping ProgressHandler) async throws
    /// IP addresses of a running guest (VM: needs the QEMU guest agent; container: its interfaces), IPv4 first.
    func guestAddresses(_ guest: VirtualGuest) async throws -> [String]
    /// Name of the hypervisor node the app is connected to (Proxmox), for shell commands run there.
    func hostNode() async -> String?
    /// MAC address and broadcast of the network port the app talks to, for Wake-on-LAN. `nil` when unknown.
    func wakeOnLANInfo() async -> WakeOnLANConfig?
    /// Newest first. Proxmox' "current" pseudo-entry is left out.
    func snapshots(of guest: VirtualGuest) async throws -> [GuestSnapshot]
    func createSnapshot(of guest: VirtualGuest, name: String, description: String, includeMemory: Bool, progress: @escaping ProgressHandler) async throws
    func rollback(_ guest: VirtualGuest, to snapshot: String, progress: @escaping ProgressHandler) async throws
    func deleteSnapshot(_ snapshot: String, of guest: VirtualGuest, progress: @escaping ProgressHandler) async throws

    // MARK: Writes
    //
    // Writes are never retried automatically. Long-running ones report progress and
    // return only when the NAS has finished (or, for DSM updates, is back after the reboot).

    /// Actions the NAS rejected with "no permission" during this session.
    func deniedActions() async -> Set<WriteAction>
    func setPackage(_ id: String, running: Bool) async throws
    func installPackageUpdate(_ id: String, progress: @escaping ProgressHandler) async throws
    /// Downloads and installs the DSM update, then waits for the reboot and signs in again.
    func installSystemUpdate(progress: @escaping ProgressHandler) async throws
    func perform(_ action: ContainerAction, container name: String) async throws
    func perform(_ action: ProjectAction, project id: String) async throws

    // MARK: Control Panel
    func updateSettings() async throws -> UpdateSettings
    func setUpdatePolicy(_ policy: UpdatePolicy) async throws
    func users() async throws -> [NASUser]
    func setUser(_ name: String, disabled: Bool) async throws
    func terminalSettings() async throws -> TerminalSettings
    func setSSH(enabled: Bool) async throws
    func activeConnections() async throws -> [ActiveConnection]
    /// Restart waits until the NAS is back and signed in again; shut down returns once DSM accepted it.
    func perform(_ action: PowerAction, progress: @escaping ProgressHandler) async throws
    /// The account this app is signed in with (never offered for disabling).
    func signedInUser() async -> String

    // MARK: File Station
    func sharedFolders() async throws -> [FileItem]
    func folderContents(_ path: String) async throws -> [FileItem]
    func transfer(_ path: String, to destination: String, mode: TransferMode, progress: @escaping ProgressHandler) async throws
    func createFolder(named name: String, in folder: String) async throws
    /// Deletes files or folders (folders recursively). Returns when the NAS has finished.
    func delete(_ paths: [String], progress: @escaping ProgressHandler) async throws

    // MARK: Hyper Backup
    func backupTasks() async throws -> [BackupTask]
    /// Returns once the NAS accepted the request; the backup itself keeps running on the NAS.
    func perform(_ control: BackupControl, backup id: String) async throws

    // MARK: Snapshot Replication
    /// Shared folders that support snapshots, with their snapshots.
    func shareSnapshots() async throws -> [ShareSnapshots]
    func takeSnapshot(of share: String, description: String) async throws
    func replicationPlans() async throws -> [ReplicationPlan]
    /// Returns once the NAS accepted the request; the sync runs on the NAS.
    func syncReplication(_ planID: String) async throws

    // MARK: Security Advisor
    /// Result of the last scan, or the progress of the one that is running.
    func securityReport() async throws -> SecurityScanReport
    /// Returns once the NAS accepted the request; the scan runs on the NAS.
    func startSecurityScan() async throws
}

public extension ServerBackend {
    func hostNode() async -> String? { nil }
    func wakeOnLANInfo() async -> WakeOnLANConfig? { nil }
    func snapshots(of guest: VirtualGuest) async throws -> [GuestSnapshot] { throw BackendError.notSupported }
    func createSnapshot(of guest: VirtualGuest, name: String, description: String, includeMemory: Bool, progress: @escaping ProgressHandler) async throws {
        throw BackendError.notSupported
    }
    func rollback(_ guest: VirtualGuest, to snapshot: String, progress: @escaping ProgressHandler) async throws { throw BackendError.notSupported }
    func deleteSnapshot(_ snapshot: String, of guest: VirtualGuest, progress: @escaping ProgressHandler) async throws { throw BackendError.notSupported }
    func securityReport() async throws -> SecurityScanReport { throw BackendError.notSupported }
    func startSecurityScan() async throws { throw BackendError.notSupported }
}
