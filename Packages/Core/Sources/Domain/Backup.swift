import Foundation

// Hyper Backup: see whether backups ran, start one now or cancel a running one.

/// What a backup task is doing right now.
public enum BackupActivity: Sendable, Hashable {
    case idle
    /// Progress 0…1 when the NAS reports it.
    case running(progress: Double?)
    case waiting
    /// Integrity check or version cleanup.
    case maintenance
    case suspended

    public var isBusy: Bool {
        switch self {
        case .running, .waiting, .maintenance: true
        case .idle, .suspended: false
        }
    }
}

/// Outcome of the last backup run.
public enum BackupResult: String, Sendable, Hashable {
    case success
    /// Finished, but some files were skipped.
    case partial
    case failed
    case cancelled
}

/// Where a task backs up to.
public enum BackupDestination: Sendable, Hashable {
    case local
    case remoteNAS
    case cloud(String?)
    case other(String)
}

public struct BackupTask: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var destination: BackupDestination
    public var activity: BackupActivity
    public var lastResult: BackupResult?
    public var lastBackup: Date?
    public var nextBackup: Date?
    /// Whether the destination answered the last check. nil = not checked or the NAS does not say.
    public var targetOnline: Bool?

    public init(
        id: String,
        name: String,
        destination: BackupDestination,
        activity: BackupActivity = .idle,
        lastResult: BackupResult? = nil,
        lastBackup: Date? = nil,
        nextBackup: Date? = nil,
        targetOnline: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.destination = destination
        self.activity = activity
        self.lastResult = lastResult
        self.lastBackup = lastBackup
        self.nextBackup = nextBackup
        self.targetOnline = targetOnline
    }

    public var isTargetOffline: Bool { targetOnline == false }

    /// The last run failed or did not complete; worth a look.
    public var needsAttention: Bool {
        lastResult == .failed || lastResult == .partial
    }
}

public enum BackupControl: String, Sendable, Hashable {
    case start, cancel
}
