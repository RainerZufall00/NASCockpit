import Foundation

/// SYNO.Core.Upgrade.Setting / get (UNVERIFIED keys)
struct UpdateSettingsDTO: Decodable, Sendable {
    let autoUpdateEnabled: Bool?
    let autoUpdateType: String?
    let schedule: String?

    private enum CodingKeys: String, CodingKey { case autoupdate_enable, autoupdate_type, schedule }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoUpdateEnabled = c.lossyBool(.autoupdate_enable)
        autoUpdateType = c.lossyString(.autoupdate_type)
        if let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .schedule),
           let hour = nested.lossyInt(AnyKey("hour")) {
            let minute = nested.lossyInt(AnyKey("minute")) ?? 0
            let days = nested.lossyString(AnyKey("week_day")) ?? nested.lossyString(AnyKey("weekdays"))
            let time = String(format: "%02d:%02d", hour, minute)
            schedule = days.map { "\(DSMMapping.weekdayNames($0)) \(time)" } ?? time
        } else {
            schedule = nil
        }
    }
}

/// SYNO.Core.User / list (UNVERIFIED `additional` fields)
struct UserListDTO: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let name: String
        let description: String?
        let email: String?
        let expired: String?

        private enum CodingKeys: String, CodingKey { case name, description, email, expired, additional }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lossyString(.name) ?? ""
            let extra = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .additional)
            description = c.lossyString(.description) ?? extra?.lossyString(.description)
            email = c.lossyString(.email) ?? extra?.lossyString(.email)
            expired = c.lossyString(.expired) ?? extra?.lossyString(.expired)
        }
    }

    let users: [User]

    private enum CodingKeys: String, CodingKey { case users }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = c.lossyArray(User.self, .users).filter { !$0.name.isEmpty }
    }
}

/// SYNO.Core.Terminal / get
struct TerminalDTO: Decodable, Sendable {
    let sshEnabled: Bool
    let sshPort: Int?

    private enum CodingKeys: String, CodingKey { case enable_ssh, ssh_port }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sshEnabled = c.lossyBool(.enable_ssh) ?? false
        sshPort = c.lossyInt(.ssh_port)
    }
}

/// SYNO.Core.CurrentConnection / list (UNVERIFIED)
struct ConnectionListDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let who: String?
        let from: String?
        let type: String?
        let time: String?

        private enum CodingKeys: String, CodingKey { case who, from, type, time }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            who = c.lossyString(.who)
            from = c.lossyString(.from)
            type = c.lossyString(.type)
            time = c.lossyString(.time)
        }
    }

    let items: [Item]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lossyArray(Item.self, .items)
    }
}

/// SYNO.FileStation.List / list_share and list (official)
struct FileListDTO: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?

        private enum CodingKeys: String, CodingKey { case path, name, isdir, additional }
        private enum Additional: String, CodingKey { case size, time }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.lossyString(.path) ?? ""
            name = c.lossyString(.name) ?? (path.split(separator: "/").last.map(String.init) ?? path)
            isDirectory = c.lossyBool(.isdir) ?? false
            let extra = try? c.nestedContainer(keyedBy: Additional.self, forKey: .additional)
            size = extra?.lossyInt64(.size)
            let time = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .time)
            modified = time?.lossyDouble(AnyKey("mtime")).map { Date(timeIntervalSince1970: $0) }
        }
    }

    let entries: [Entry]
    let total: Int?

    private enum CodingKeys: String, CodingKey { case shares, files, total }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let shares = c.lossyArray(Entry.self, .shares)
        entries = (shares.isEmpty ? c.lossyArray(Entry.self, .files) : shares).filter { !$0.path.isEmpty }
        total = c.lossyInt(.total)
    }
}
