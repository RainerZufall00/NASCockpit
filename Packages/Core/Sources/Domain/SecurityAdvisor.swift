import Foundation

// Security Advisor (DSM): the result of the last security scan and the scan that is running.

/// DSM's result levels, from harmless to most severe.
public enum SecuritySeverity: String, Sendable, Hashable, CaseIterable, Comparable {
    case safe, info, outOfDate, warning, risk, danger

    /// Lenient: DSM's words in any letter case; unknown words count as `nil`.
    public init?(dsm value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "safe", "pass", "passed", "ok", "normal": self = .safe
        case "info", "information": self = .info
        case "outofdate", "out_of_date", "outdated": self = .outOfDate
        case "warning", "warn": self = .warning
        case "risk": self = .risk
        case "danger", "critical", "high": self = .danger
        default: return nil
        }
    }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .info: 1
        case .outOfDate: 2
        case .warning: 3
        case .risk: 4
        case .danger: 5
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Worth a look (everything above "info").
    public var needsAttention: Bool { self >= .outOfDate }
}

/// One check category of the scan, e.g. "malware" or "network".
public struct SecurityCheckGroup: Identifiable, Sendable, Hashable {
    /// DSM's category key, e.g. "malware", "systemCheck", "userInfo", "network", "update", "securitySetting".
    public var id: String
    /// Number of checks in this category.
    public var total: Int
    /// Failed checks per severity (`.safe` is never a key).
    public var failures: [SecuritySeverity: Int]
    /// Worst result in this category.
    public var severity: SecuritySeverity
    /// 0…1 while the scan runs, `nil` when unknown.
    public var progress: Double?
    public var isRunning: Bool

    public init(id: String, total: Int, failures: [SecuritySeverity: Int] = [:], severity: SecuritySeverity = .safe, progress: Double? = nil, isRunning: Bool = false) {
        self.id = id
        self.total = total
        self.failures = failures.filter { $0.key != .safe && $0.value > 0 }
        self.severity = severity
        self.progress = progress
        self.isRunning = isRunning
    }

    public var failedCount: Int { failures.values.reduce(0, +) }
    public var passedCount: Int { max(0, total - failedCount) }
    /// Failed checks that are worth a look (above "info").
    public var issueCount: Int { failures.filter { $0.key.needsAttention }.values.reduce(0, +) }

    /// Known categories first, in DSM's order; unknown ones after them by name.
    public var sortKey: (Int, String) {
        let order = ["malware", "systemCheck", "securitySetting", "userInfo", "network", "update"]
        return (order.firstIndex(of: id) ?? order.count, id)
    }
}

/// A single check that did not pass.
public struct SecurityFinding: Identifiable, Sendable, Hashable {
    public var id: String
    /// Category key, matches `SecurityCheckGroup.id`.
    public var group: String
    public var title: String
    public var severity: SecuritySeverity

    public init(id: String, group: String, title: String, severity: SecuritySeverity) {
        self.id = id
        self.group = group
        self.title = title
        self.severity = severity
    }
}

public struct SecurityScanReport: Sendable, Hashable {
    /// Overall result of the last scan (DSM's `sysStatus`).
    public var overall: SecuritySeverity
    public var isScanning: Bool
    /// 0…1 while scanning, when DSM reports it.
    public var progress: Double?
    public var lastScan: Date?
    public var groups: [SecurityCheckGroup]
    /// Failed checks, most severe first. Empty when DSM does not list them.
    public var findings: [SecurityFinding]

    public init(
        overall: SecuritySeverity,
        isScanning: Bool = false,
        progress: Double? = nil,
        lastScan: Date? = nil,
        groups: [SecurityCheckGroup] = [],
        findings: [SecurityFinding] = []
    ) {
        self.overall = overall
        self.isScanning = isScanning
        self.progress = progress
        self.lastScan = lastScan
        self.groups = groups.sorted { $0.sortKey < $1.sortKey }
        self.findings = findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public var hasBeenScanned: Bool { lastScan != nil }
    public var checkCount: Int { groups.reduce(0) { $0 + $1.total } }
    public var failedCount: Int { groups.reduce(0) { $0 + $1.failedCount } }
    /// Failed checks above "info".
    public var issueCount: Int { groups.reduce(0) { $0 + $1.issueCount } }

    public func findings(in group: String) -> [SecurityFinding] {
        findings.filter { $0.group == group }
    }
}
