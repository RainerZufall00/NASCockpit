import Foundation

// Snapshot Replication: snapshots of shared folders and replication plans to another NAS.

public struct SnapshotItem: Identifiable, Sendable, Hashable {
    /// DSM's snapshot name, e.g. "GMT+01-2026.11.08-03.00.02".
    public var id: String
    public var date: Date?
    public var description: String?
    /// Locked snapshots are kept by retention.
    public var isLocked: Bool
    /// Immutable (WORM) snapshots cannot be deleted until the lock ends.
    public var isImmutable: Bool
    /// Taken by the schedule (not by hand).
    public var isScheduled: Bool

    public init(id: String, date: Date?, description: String? = nil, isLocked: Bool = false, isImmutable: Bool = false, isScheduled: Bool = false) {
        self.id = id
        self.date = date
        self.description = description
        self.isLocked = isLocked
        self.isImmutable = isImmutable
        self.isScheduled = isScheduled
    }
}

/// One shared folder that supports snapshots, newest snapshot first.
public struct ShareSnapshots: Identifiable, Sendable, Hashable {
    public var id: String { share }
    public var share: String
    public var snapshots: [SnapshotItem]

    public init(share: String, snapshots: [SnapshotItem]) {
        self.share = share
        self.snapshots = snapshots.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public var latest: SnapshotItem? { snapshots.first }
}

public struct ReplicationPlan: Identifiable, Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        /// This NAS sends.
        case source
        /// This NAS receives.
        case destination
    }

    public var id: String
    /// Usually the shared folder (or LUN) being replicated.
    public var name: String
    public var role: Role
    /// The other NAS, or nil for a replication on the same NAS.
    public var partner: String?
    public var isSyncing: Bool
    /// 0…1 while syncing, when the NAS reports it.
    public var progress: Double?
    public var lastSync: Date?
    public var lastSyncSucceeded: Bool?
    public var nextSync: Date?
    public var failedSyncCount: Int
    public var canSync: Bool

    public init(
        id: String,
        name: String,
        role: Role = .source,
        partner: String? = nil,
        isSyncing: Bool = false,
        progress: Double? = nil,
        lastSync: Date? = nil,
        lastSyncSucceeded: Bool? = nil,
        nextSync: Date? = nil,
        failedSyncCount: Int = 0,
        canSync: Bool = true
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.partner = partner
        self.isSyncing = isSyncing
        self.progress = progress
        self.lastSync = lastSync
        self.lastSyncSucceeded = lastSyncSucceeded
        self.nextSync = nextSync
        self.failedSyncCount = failedSyncCount
        self.canSync = canSync
    }

    public var needsAttention: Bool { lastSyncSucceeded == false }
}
