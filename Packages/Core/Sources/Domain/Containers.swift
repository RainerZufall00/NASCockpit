import Foundation

public enum ContainerStatus: String, Sendable, Hashable, Codable {
    case running, stopped, exited, paused, restarting, created, unknown

    public var isRunning: Bool { self == .running || self == .restarting }
}

public struct ContainerItem: Identifiable, Sendable, Hashable, Codable {
    /// DSM addresses containers by name.
    public var id: String { name }
    public var name: String
    public var image: String?
    public var status: ContainerStatus
    public var exitCode: Int?
    public var startedAt: Date?
    public var cpuPercent: Double?
    public var memoryBytes: Int64?
    public var projectName: String?

    public init(name: String, image: String? = nil, status: ContainerStatus, exitCode: Int? = nil, startedAt: Date? = nil, cpuPercent: Double? = nil, memoryBytes: Int64? = nil, projectName: String? = nil) {
        self.name = name
        self.image = image
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.projectName = projectName
    }

    /// Stopped with an exit code other than 0. A clean stop (exit code 0) is not a failure.
    public var hasFailed: Bool {
        !status.isRunning && (exitCode ?? 0) != 0
    }
}

public enum ProjectStatus: String, Sendable, Hashable, Codable {
    case running, stopped, partial, unknown
}

public struct ComposeProject: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var status: ProjectStatus
    public var containerNames: [String]
    public var path: String?

    public init(id: String, name: String, status: ProjectStatus, containerNames: [String], path: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.containerNames = containerNames
        self.path = path
    }
}

public enum ContainerAction: String, Sendable, Hashable, CaseIterable {
    case start, stop, restart
}

/// Compose projects in the MVP: start, stop and rebuild. A compose.yaml editor comes later.
public enum ProjectAction: String, Sendable, Hashable, CaseIterable {
    case start, stop, rebuild
}

public struct ContainerLogLine: Identifiable, Sendable, Hashable {
    public var id: Int
    public var date: Date?
    public var stream: String?
    public var text: String

    public init(id: Int, date: Date?, stream: String?, text: String) {
        self.id = id
        self.date = date
        self.stream = stream
        self.text = text
    }
}

/// Groups of write actions. If DSM rejects one with 105 (no permission), the UI hides it for that NAS.
public enum WriteAction: String, Sendable, Hashable, CaseIterable {
    case packageControl, packageUpdate, systemUpdate, containerControl, projectControl
    case updateSettings, userControl, terminal, power, fileTransfer, createFolder, deleteFiles, backupControl
    case snapshot, replicationSync
    /// Start, stop, shut down, reboot virtual machines and containers (Proxmox).
    case guestControl
    /// Create, roll back and delete snapshots of VMs and containers (Proxmox).
    case guestSnapshot
    /// Refresh the server's list of available updates (Proxmox `apt update`, DSM package catalog).
    case refreshCatalog
}

/// Progress 0…1, or `nil` when the step has no measurable progress.
public typealias ProgressHandler = @Sendable (Double?) -> Void
