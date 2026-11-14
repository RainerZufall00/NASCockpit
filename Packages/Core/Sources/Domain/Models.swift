import Foundation

/// Areas a backend can offer. The UI only shows what is present.
public enum Capability: String, Codable, Sendable, CaseIterable {
    case dashboard, packages, systemUpdate, containers, logs, files, settings, vms, backup, backupLogs
    case snapshots, replication
    /// Snapshots of VMs and containers (Proxmox).
    case guestSnapshots
    /// The NAS's own notification list.
    case notifications
    /// DSM Security Advisor: scan results and "Scan Now".
    case securityAdvisor
    // Control Panel areas, each detected separately.
    case updateSettings, users, terminal, power, connections
}

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case needsOTP
    case connected
    case reauthenticating
    case rebooting
    case failed(BackendError)

    public var isConnected: Bool {
        switch self {
        case .connected, .reauthenticating: true
        default: false
        }
    }
}

public enum HealthStatus: String, Sendable, Hashable, Codable {
    case normal, warning, degraded, crashed, unknown

    public var isProblem: Bool { self == .degraded || self == .crashed || self == .warning }
}

public struct VolumeInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var status: HealthStatus
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var fileSystem: String?

    public init(id: String, name: String, status: HealthStatus, totalBytes: Int64, usedBytes: Int64, fileSystem: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.fileSystem = fileSystem
    }

    public var usage: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

public struct DiskInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var model: String?
    public var temperature: Double?
    public var status: HealthStatus

    public init(id: String, name: String, model: String? = nil, temperature: Double? = nil, status: HealthStatus) {
        self.id = id
        self.name = name
        self.model = model
        self.temperature = temperature
        self.status = status
    }
}

public struct NetworkThroughput: Sendable, Hashable, Codable {
    public var rxBytesPerSecond: Double
    public var txBytesPerSecond: Double

    public init(rxBytesPerSecond: Double, txBytesPerSecond: Double) {
        self.rxBytesPerSecond = rxBytesPerSecond
        self.txBytesPerSecond = txBytesPerSecond
    }
}

public struct SystemSnapshot: Sendable, Hashable, Codable {
    public var model: String
    public var osVersion: String
    public var uptime: TimeInterval?
    public var temperature: Double?
    public var temperatureWarning: Bool
    /// 0…1
    public var cpuLoad: Double?
    /// 0…1
    public var memoryUsage: Double?
    public var memoryTotalBytes: Int64?
    public var network: NetworkThroughput?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var volumes: [VolumeInfo]
    public var disks: [DiskInfo]
    public var capturedAt: Date

    public init(
        model: String,
        osVersion: String,
        uptime: TimeInterval? = nil,
        temperature: Double? = nil,
        temperatureWarning: Bool = false,
        cpuLoad: Double? = nil,
        memoryUsage: Double? = nil,
        memoryTotalBytes: Int64? = nil,
        network: NetworkThroughput? = nil,
        diskReadBytesPerSecond: Double? = nil,
        diskWriteBytesPerSecond: Double? = nil,
        volumes: [VolumeInfo] = [],
        disks: [DiskInfo] = [],
        capturedAt: Date = .now
    ) {
        self.model = model
        self.osVersion = osVersion
        self.uptime = uptime
        self.temperature = temperature
        self.temperatureWarning = temperatureWarning
        self.cpuLoad = cpuLoad
        self.memoryUsage = memoryUsage
        self.memoryTotalBytes = memoryTotalBytes
        self.network = network
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.volumes = volumes
        self.disks = disks
        self.capturedAt = capturedAt
    }

    public var highestVolumeUsage: Double? { volumes.map(\.usage).max() }

    public var hasStorageProblem: Bool {
        volumes.contains { $0.status.isProblem || $0.usage > 0.9 } || disks.contains { $0.status.isProblem }
    }
}

public enum PackageStatus: String, Sendable, Hashable, Codable {
    case running, stopped, transitioning, broken, unknown
}

public struct PackageItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var status: PackageStatus
    public var availableVersion: String?
    public var summary: String?

    public init(id: String, name: String, version: String, status: PackageStatus, availableVersion: String? = nil, summary: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.status = status
        self.availableVersion = availableVersion
        self.summary = summary
    }

    public var hasUpdate: Bool { availableVersion != nil }
}

public struct UpdateItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case package(id: String)
        case system
    }

    public var id: String
    public var serverID: ServerID
    public var kind: Kind
    public var name: String
    public var installedVersion: String?
    public var availableVersion: String
    public var requiresReboot: Bool

    public init(serverID: ServerID, kind: Kind, name: String, installedVersion: String?, availableVersion: String, requiresReboot: Bool) {
        switch kind {
        case .package(let packageID): id = "\(serverID.uuidString)/package/\(packageID)"
        case .system: id = "\(serverID.uuidString)/system"
        }
        self.serverID = serverID
        self.kind = kind
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.requiresReboot = requiresReboot
    }

    public var isSystemUpdate: Bool { kind == .system }
}

public enum LogLevel: String, Sendable, Hashable, CaseIterable, Codable {
    case info, warning, error
}

public struct LogEntry: Identifiable, Sendable, Hashable {
    /// Position in the server-side log (offset based, stable within one query).
    public var id: Int
    public var date: Date?
    public var level: LogLevel
    public var category: String
    public var user: String?
    public var message: String

    public init(id: Int, date: Date?, level: LogLevel, category: String, user: String?, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.user = user
        self.message = message
    }
}

/// Which log to read.
public enum LogSource: String, Sendable, Hashable, CaseIterable {
    /// DSM's general log (Log Center → System).
    case system
    /// Sign-ins and connections.
    case connection
    /// Hyper Backup's own log.
    case backup
}

public struct LogQuery: Sendable, Hashable {
    public var source: LogSource
    public var offset: Int
    public var limit: Int
    public var keyword: String?
    public var levels: Set<LogLevel>
    public var from: Date?
    public var to: Date?
    /// Hyper Backup only: entries of this task (matched by the task-name prefix DSM writes).
    public var backupTask: String?

    public init(
        source: LogSource = .system,
        offset: Int = 0,
        limit: Int = 100,
        keyword: String? = nil,
        levels: Set<LogLevel> = Set(LogLevel.allCases),
        from: Date? = nil,
        to: Date? = nil,
        backupTask: String? = nil
    ) {
        self.source = source
        self.offset = offset
        self.limit = limit
        self.keyword = keyword
        self.levels = levels
        self.from = from
        self.to = to
        self.backupTask = backupTask
    }

    public func matches(_ entry: LogEntry) -> Bool {
        guard levels.contains(entry.level) else { return false }
        if let backupTask, entry.category.caseInsensitiveCompare(backupTask) != .orderedSame { return false }
        if let date = entry.date {
            if let from, date < from { return false }
            if let to, date > to { return false }
        }
        return true
    }
}

public struct LogPage: Sendable, Hashable {
    public var entries: [LogEntry]
    public var total: Int
    /// Offset for the next page, `nil` when everything was loaded.
    public var nextOffset: Int?

    public init(entries: [LogEntry], total: Int, nextOffset: Int?) {
        self.entries = entries
        self.total = total
        self.nextOffset = nextOffset
    }
}
