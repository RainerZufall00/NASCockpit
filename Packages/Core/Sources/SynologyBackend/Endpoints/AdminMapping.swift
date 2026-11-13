import Foundation
import Domain

extension DSMMapping {
    static func updateSettings(_ dto: UpdateSettingsDTO) -> UpdateSettings {
        let policy: UpdatePolicy
        if dto.autoUpdateEnabled == false {
            policy = .notifyOnly
        } else if let type = dto.autoUpdateType?.lowercased() {
            policy = type == "all" || type.contains("major") || type.contains("latest") ? .all : .importantOnly
        } else {
            policy = dto.autoUpdateEnabled == true ? .importantOnly : .notifyOnly
        }
        return UpdateSettings(policy: policy, schedule: dto.schedule)
    }

    /// "0,6" → "Sun, Sat" (DSM counts Sunday as 0).
    static func weekdayNames(_ raw: String) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !days.isEmpty, days.allSatisfy({ (0..<7).contains($0) }) else { return raw }
        if days.count == 7 { return String(localized: "Daily") }
        return days.map { symbols[$0] }.joined(separator: ", ")
    }

    static func users(_ dto: UserListDTO) -> [NASUser] {
        dto.users
            .map { user in
                let expired = user.expired?.lowercased() ?? "normal"
                // "normal" = active; "now" or a past date = disabled.
                var disabled = expired != "normal" && !expired.isEmpty
                if let date = parseExpiryDate(expired) { disabled = date <= .now }
                return NASUser(
                    name: user.name,
                    fullName: user.description.flatMap { $0.isEmpty ? nil : $0 },
                    email: user.email.flatMap { $0.isEmpty ? nil : $0 },
                    isDisabled: disabled
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseExpiryDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/M/d"
        return formatter.date(from: string)
    }

    static func connections(_ dto: ConnectionListDTO) -> [ActiveConnection] {
        dto.items.map { item in
            ActiveConnection(
                user: item.who ?? "-",
                address: item.from ?? "-",
                kind: item.type ?? "-",
                since: item.time.flatMap(parseConnectionTime)
            )
        }
    }

    /// Epoch seconds or "yyyy/MM/dd HH:mm:ss".
    static func parseConnectionTime(_ string: String) -> Date? {
        if let seconds = Double(string), seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        return parseLogDate(string)
    }

    static func files(_ dto: FileListDTO) -> [FileItem] {
        FileItem.sorted(dto.entries.map {
            FileItem(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.isDirectory ? nil : $0.size, modified: $0.modified)
        })
    }
}
