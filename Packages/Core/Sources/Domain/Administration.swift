import Foundation

// Control Panel: what an admin needs on the go.

/// How DSM handles new DSM versions.
public enum UpdatePolicy: String, Sendable, Hashable, CaseIterable {
    /// Notify only; the admin decides.
    case notifyOnly
    /// Install important (security) updates automatically.
    case importantOnly
    /// Install every DSM update automatically.
    case all
}

public struct UpdateSettings: Sendable, Hashable {
    public var policy: UpdatePolicy
    /// Human-readable schedule as DSM reports it, e.g. "Sunday 03:00". nil if unknown.
    public var schedule: String?

    public init(policy: UpdatePolicy, schedule: String? = nil) {
        self.policy = policy
        self.schedule = schedule
    }
}

public struct NASUser: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var fullName: String?
    public var email: String?
    /// Account disabled ("expired") in DSM.
    public var isDisabled: Bool

    public init(name: String, fullName: String? = nil, email: String? = nil, isDisabled: Bool) {
        self.name = name
        self.fullName = fullName
        self.email = email
        self.isDisabled = isDisabled
    }
}

public struct TerminalSettings: Sendable, Hashable {
    public var sshEnabled: Bool
    public var sshPort: Int?

    public init(sshEnabled: Bool, sshPort: Int? = nil) {
        self.sshEnabled = sshEnabled
        self.sshPort = sshPort
    }
}

/// Someone signed in to the NAS right now (DSM, SMB, AFP, SSH …).
public struct ActiveConnection: Identifiable, Sendable, Hashable {
    public var id: String { "\(user)|\(address)|\(kind)|\(since?.timeIntervalSince1970 ?? 0)" }
    public var user: String
    public var address: String
    public var kind: String
    public var since: Date?

    public init(user: String, address: String, kind: String, since: Date?) {
        self.user = user
        self.address = address
        self.kind = kind
        self.since = since
    }
}

public enum PowerAction: String, Sendable, Hashable {
    case restart, shutDown
}
