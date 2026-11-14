import Foundation
import Domain

// Security Advisor. UNVERIFIED against DSM 7.2:
// - `SYNO.Core.SecurityScan.Status` / `system_get`: shape from the py-synologydsm-api test data (DSM 6),
//   which Home Assistant uses: `sysStatus`, `sysProgress`, `lastScanTime`, `startTime`, `items.<category>`
//   with `total`, `fail.<severity>`, `failSeverity`, `progress`, `runningItem`, `waitNum`.
// - `SYNO.Core.SecurityScan.Status` / `rule_get` with `items=ALL`: called by the synology-api library, but no
//   example answer is published. Parsed leniently (object or array of rules); without usable rules the app shows
//   the counts per category only.
// - `SYNO.Core.SecurityScan.Operation` / `start`: from the synology-api library. When DSM says the method does
//   not exist, the app tries `specific_start` with `items=ALL` (seen in the DSM web UI).

extension DSMEndpoints {
    enum SecurityScan {
        static let statusAPI = "SYNO.Core.SecurityScan.Status"
        static let operationAPI = "SYNO.Core.SecurityScan.Operation"

        static var status: DSMEndpoint<SecurityStatusDTO> {
            DSMEndpoint(api: statusAPI, method: "system_get", versions: 1...1, timeout: 20)
        }

        static var rules: DSMEndpoint<SecurityRulesDTO> {
            DSMEndpoint(api: statusAPI, method: "rule_get", versions: 1...1, params: ["items": "ALL"], timeout: 20)
        }

        static var start: DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: operationAPI, method: "start", versions: 1...1, isWrite: true, timeout: 30)
        }

        static var specificStart: DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: operationAPI, method: "specific_start", versions: 1...1, params: ["items": "ALL"], isWrite: true, timeout: 30)
        }
    }
}

/// SYNO.Core.SecurityScan.Status / system_get
struct SecurityStatusDTO: Decodable, Sendable {
    struct Category: Sendable {
        let key: String
        let total: Int
        let failures: [String: Int]
        let failSeverity: String?
        let progress: Double?
        let runningItem: String?
        let waitNum: Int
    }

    let sysStatus: String?
    let sysProgress: Double?
    let lastScanTime: Date?
    let startTime: String?
    let categories: [Category]

    private enum CodingKeys: String, CodingKey { case sysStatus, sysProgress, lastScanTime, startTime, items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sysStatus = c.lossyString(.sysStatus)
        sysProgress = c.lossyDouble(.sysProgress)
        lastScanTime = c.lossyDouble(.lastScanTime).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        startTime = c.lossyString(.startTime).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }

        var categories: [Category] = []
        if let items = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .items) {
            for key in items.allKeys {
                guard let item = try? items.nestedContainer(keyedBy: AnyKey.self, forKey: key) else { continue }
                var failures: [String: Int] = [:]
                if let fail = try? item.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("fail")) {
                    for level in fail.allKeys {
                        if let count = fail.lossyInt(level), count > 0 { failures[level.stringValue] = count }
                    }
                }
                categories.append(Category(
                    key: item.lossyString(AnyKey("category")).flatMap { $0.isEmpty ? nil : $0 } ?? key.stringValue,
                    total: item.lossyInt(AnyKey("total")) ?? 0,
                    failures: failures,
                    failSeverity: item.lossyString(AnyKey("failSeverity")),
                    progress: item.lossyDouble(AnyKey("progress")),
                    runningItem: item.lossyString(AnyKey("runningItem")).flatMap { $0.isEmpty ? nil : $0 },
                    waitNum: item.lossyInt(AnyKey("waitNum")) ?? 0
                ))
            }
        }
        self.categories = categories
    }
}

/// SYNO.Core.SecurityScan.Status / rule_get. Shape unknown: accepts `items` (or `rules`) as an object keyed by
/// rule ID or as an array, each rule with some of `category`, `status`/`result`, `severity`/`failSeverity`
/// and a title-like field.
struct SecurityRulesDTO: Decodable, Sendable {
    struct Rule: Sendable {
        let id: String
        let category: String?
        let status: String?
        let severity: String?
        let title: String?
    }

    let rules: [Rule]

    private enum CodingKeys: String, CodingKey { case items, rules }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(JSONValue.self, forKey: .items)) ?? (try? c.decodeIfPresent(JSONValue.self, forKey: .rules)) ?? nil
        var rules: [Rule] = []
        switch raw {
        case .object(let byID)?:
            for (key, value) in byID {
                if case .object(let fields) = value { rules.append(Self.rule(fields, fallbackID: key)) }
            }
        case .array(let list)?:
            for (index, value) in list.enumerated() {
                if case .object(let fields) = value { rules.append(Self.rule(fields, fallbackID: "rule-\(index)")) }
            }
        default:
            break
        }
        self.rules = rules
    }

    private static func rule(_ fields: [String: JSONValue], fallbackID: String) -> Rule {
        func text(_ keys: String...) -> String? {
            for key in keys {
                switch fields[key] {
                case .string(let value)? where !value.isEmpty: return value
                case .number(let value)?: return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
                case .bool(let value)?: return value ? "true" : "false"
                default: continue
                }
            }
            return nil
        }
        return Rule(
            id: text("ruleId", "rule_id", "id", "strId", "str_id") ?? fallbackID,
            category: text("category", "group"),
            status: text("status", "result", "state"),
            severity: text("failSeverity", "severity", "level"),
            title: text("title", "name", "desc", "description", "strId", "str_id")
        )
    }
}

extension DSMMapping {
    static func securityReport(_ status: SecurityStatusDTO, rules: SecurityRulesDTO?) -> SecurityScanReport {
        let groups = status.categories.map { category in
            var failures: [SecuritySeverity: Int] = [:]
            for (level, count) in category.failures {
                guard let severity = SecuritySeverity(dsm: level), severity != .safe else { continue }
                failures[severity, default: 0] += count
            }
            let worst = failures.keys.max() ?? .safe
            let progress = category.progress.map { min(1, max(0, $0 / 100)) }
            return SecurityCheckGroup(
                id: category.key,
                total: category.total,
                failures: failures,
                severity: max(SecuritySeverity(dsm: category.failSeverity) ?? worst, worst),
                progress: progress,
                isRunning: category.runningItem != nil || category.waitNum > 0
            )
        }

        let progress = status.sysProgress.map { min(1, max(0, $0 / 100)) }
        let unfinished = (progress ?? 1) < 1
        let isScanning = unfinished && (status.startTime != nil || groups.contains(where: \.isRunning))
        let overall = SecuritySeverity(dsm: status.sysStatus) ?? groups.map(\.severity).max() ?? .safe

        let findings: [SecurityFinding] = (rules?.rules ?? []).compactMap { rule in
            let severity = SecuritySeverity(dsm: rule.severity)
            let failed: Bool = switch rule.status?.lowercased() ?? "" {
            case "fail", "failed", "false", "danger", "risk", "warning", "outofdate", "info": true
            case "pass", "passed", "true", "safe", "skip", "skipped", "running", "wait", "waiting", "disabled", "none", "ok": false
            default: severity.map { $0 != .safe } ?? false
            }
            guard failed else { return nil }
            // A failed rule without its own level takes the status word, or "warning".
            var level = SecuritySeverity.warning
            if let severity, severity != .safe {
                level = severity
            } else if let word = SecuritySeverity(dsm: rule.status), word != .safe {
                level = word
            }
            // Real text stays as it is; UI string keys ("rule_ssh_default_port") become words.
            let title: String
            if let text = rule.title, text.contains(" ") {
                title = text
            } else {
                title = securityRuleTitle(rule.title ?? rule.id)
            }
            return SecurityFinding(id: rule.id, group: rule.category ?? "", title: title, severity: level)
        }

        return SecurityScanReport(
            overall: overall,
            isScanning: isScanning,
            progress: isScanning ? progress : nil,
            lastScan: status.lastScanTime,
            groups: groups,
            findings: findings
        )
    }

    /// DSM names rules with UI string keys such as "securityscan:rule_admin_disabled" or "checkAdminDisabled".
    /// Without DSM's translation files the key is turned into readable words.
    static func securityRuleTitle(_ key: String) -> String {
        var name = key
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        for prefix in ["rule_", "check_", "rule", "check"] where name.lowercased().hasPrefix(prefix) && name.count > prefix.count {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return humanized(name)
    }
}
