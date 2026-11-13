import Foundation
import Domain

// DSM's notification list (the bell in the web UI).
//
// Request and response shape were checked against a response captured from a real DSM 7 (2026-11):
// `title` is an event tag ("BackupTaskFailed"), `msg[0]` a JSON string with the variables of DSM's
// own text template ("%TASK_NAME%", "%1%" …). The templates live on the NAS and are not part of the
// response, so the app writes its own titles for the tags it knows and falls back to a readable form
// of the tag. Only the tags listed in `knownTitles` were seen; everything else takes the fallback.

extension DSMEndpoints {
    enum Notify {
        static let api = "SYNO.Core.DSMNotify"

        /// `action=load` only reads; it does not mark anything as read on the NAS.
        static var load: DSMEndpoint<DSMNotifyDTO> {
            DSMEndpoint(api: api, method: "notify", versions: 1...1, params: [
                "action": "load", "lastRead": "0", "lastSeen": "0",
            ], timeout: 20)
        }
    }
}

struct DSMNotifyDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String?
        let time: Double?
        let level: String?
        let title: String
        let msg: [String]

        private enum CodingKeys: String, CodingKey { case notifyId, time, level, title, msg }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.notifyId)
            time = c.lossyDouble(.time)
            level = c.lossyString(.level)
            title = c.lossyString(.title) ?? ""
            let list = c.lossyArray(String.self, .msg)
            msg = list.isEmpty ? [c.lossyString(.msg)].compactMap { $0 } : list
        }
    }

    let items: [Item]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lossyArray(Item.self, .items)
    }
}

extension DSMMapping {
    static func notifications(_ dto: DSMNotifyDTO) -> [NASNotification] {
        dto.items.enumerated().map { index, item in
            let variables = notifyVariables(item.msg)
            let plainText = variables.isEmpty ? item.msg.joined(separator: " ") : ""
            let message = notifyMessage(event: item.title, variables: variables)
            return NASNotification(
                id: item.id ?? "\(Int(item.time ?? 0))-\(index)",
                date: Date(timeIntervalSince1970: item.time ?? 0),
                level: notifyLevel(item.level, variables: variables),
                title: notifyTitle(item.title),
                message: message.isEmpty ? plainText : message,
                details: notifyDetails(variables)
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// `msg[0]` is a JSON object as a string. Values are strings; anything else is shown as is.
    static func notifyVariables(_ msg: [String]) -> [String: String] {
        guard let first = msg.first, let data = first.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            result[pair.key] = (pair.value as? String) ?? "\(pair.value)"
        }
    }

    private static let knownTitles: [String: String] = [
        "BackupTaskFinished": String(localized: "Backup finished"),
        "BackupTaskFailed": String(localized: "Backup failed"),
        "IntegrityCheckFinishedTargetPass": String(localized: "Backup integrity check passed"),
        "SYNOSYSLOG_SEV_EXCEED": String(localized: "Error in the system log"),
        "docker_container_unexpected_exit": String(localized: "Container stopped unexpectedly"),
    ]

    static func notifyTitle(_ event: String) -> String {
        knownTitles[event] ?? humanized(event)
    }

    /// "IntegrityCheckFailed" / "share_quota_exceed" → "Integrity check failed" / "Share quota exceed".
    static func humanized(_ tag: String) -> String {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in tag {
            if character == "_" || character == "-" || character == "%" || character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        let text = words.map { $0.lowercased() }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func notifyMessage(event: String, variables: [String: String]) -> String {
        func value(_ key: String) -> String? {
            let text = variables[key]?.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        if let log = value("%SYSLOG_CONTENT%") { return log }
        if let task = value("%TASK_NAME%") {
            return [task, value("%DURATION%")].compactMap { $0 }.joined(separator: " · ")
        }
        // Positional variables of DSM's template: %1%, %2% …
        return (1...9).compactMap { value("%\($0)%") }.joined(separator: " · ")
    }

    /// The log-level notification is sent as "info" although it reports an error.
    static func notifyLevel(_ raw: String?, variables: [String: String]) -> LogLevel {
        switch variables["%SEV%"]?.lowercased() {
        case "err", "error", "crit", "alert", "emerg": return .error
        case "warn", "warning": return .warning
        default: break
        }
        let value = raw?.lowercased() ?? ""
        if value.contains("error") || value.contains("crit") { return .error }
        if value.contains("warn") { return .warning }
        return .info
    }

    private static let hiddenVariables: Set<String> = ["%DATE%", "%TIME%", "%OSNAME%", "%HOSTNAME%", "%HOST%"]

    static func notifyDetails(_ variables: [String: String]) -> [NASNotification.Detail] {
        variables.compactMap { key, value -> NASNotification.Detail? in
            let text = value.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // "DESKTOP_NOTIFY_…" are hints for DSM's own desktop, not content.
            guard key.hasPrefix("%"), !hiddenVariables.contains(key), !text.isEmpty else { return nil }
            let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            return NASNotification.Detail(label: Int(name) == nil ? humanized(name) : String(localized: "Value \(name)"), value: text)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
