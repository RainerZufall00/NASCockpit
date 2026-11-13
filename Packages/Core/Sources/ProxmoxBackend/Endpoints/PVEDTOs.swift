import Foundation

// Shapes of the Proxmox VE 8 REST API (https://pve.proxmox.com/pve-docs/api-viewer/). Everything is
// optional so a field that a future release drops or renames never breaks the whole screen.

struct TicketDTO: Decodable, Sendable {
    let ticket: String?
    let csrf: String?
    let username: String?
    let needTFA: PVEScalar?

    private enum CodingKeys: String, CodingKey {
        case ticket, username
        case csrf = "CSRFPreventionToken"
        case needTFA = "NeedTFA"
    }
}

struct DomainDTO: Decodable, Sendable {
    let realm: String
    let type: String?
    let comment: String?
    let isDefault: PVEScalar?

    private enum CodingKeys: String, CodingKey { case realm, type, comment, isDefault = "default" }
}

struct VersionDTO: Decodable, Sendable {
    let version: String?
    let release: String?
    let repoid: String?
}

struct ClusterStatusDTO: Decodable, Sendable {
    let type: String?
    let name: String?
    let local: PVEScalar?
    let online: PVEScalar?
    let quorate: PVEScalar?
}

struct NodeDTO: Decodable, Sendable {
    let node: String
    let status: String?
}

struct NodeStatusDTO: Decodable, Sendable {
    struct Memory: Decodable, Sendable {
        let total: Int64?
        let used: Int64?
    }

    struct CPUInfo: Decodable, Sendable {
        let cpus: Int?
        let model: String?
    }

    let cpu: Double?
    let memory: Memory?
    let rootfs: Memory?
    let uptime: Double?
    let pveversion: String?
    let kversion: String?
    let cpuinfo: CPUInfo?
}

struct StorageDTO: Decodable, Sendable {
    let storage: String
    let type: String?
    let content: String?
    let active: PVEScalar?
    let enabled: PVEScalar?
    let shared: PVEScalar?
    let total: Int64?
    let used: Int64?
    let avail: Int64?
}

struct DiskDTO: Decodable, Sendable {
    let devpath: String
    let model: String?
    let serial: String?
    let size: Int64?
    let type: String?
    let health: String?
    let wearout: PVEScalar?
    let used: String?
}

struct RRDPointDTO: Decodable, Sendable {
    let time: Double?
    let netin: Double?
    let netout: Double?
}

/// One entry of `/cluster/resources?type=vm`.
struct ResourceDTO: Decodable, Sendable {
    let id: String?
    let type: String?
    let vmid: Int?
    let name: String?
    let node: String?
    let status: String?
    let cpu: Double?
    let maxcpu: Double?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Double?
    let template: PVEScalar?
    let lock: String?
    let hastate: String?
    let tags: String?
}

/// `agent/network-get-interfaces`: `{"result": [{"name": "eth0", "ip-addresses": [{"ip-address": "…", "ip-address-type": "ipv4"}]}]}`
struct AgentInterfacesDTO: Decodable, Sendable {
    struct Interface: Decodable, Sendable {
        struct Address: Decodable, Sendable {
            let address: String?
            let type: String?

            private enum CodingKeys: String, CodingKey { case address = "ip-address", type = "ip-address-type" }
        }

        let name: String?
        let addresses: [Address]?

        private enum CodingKeys: String, CodingKey { case name, addresses = "ip-addresses" }
    }

    let result: [Interface]?
}

/// `lxc/{vmid}/interfaces`: `inet` is CIDR notation ("192.168.1.5/24").
struct ContainerInterfaceDTO: Decodable, Sendable {
    let name: String?
    let inet: String?
    let inet6: String?
}

struct TaskStatusDTO: Decodable, Sendable {
    let status: String?
    let exitstatus: String?
    let type: String?
    let id: String?
    let user: String?
    let starttime: Double?

    var isFinished: Bool { status?.lowercased() == "stopped" }
    var succeeded: Bool { exitstatus?.uppercased() == "OK" }
}

struct TaskListEntryDTO: Decodable, Sendable {
    let upid: String?
    let type: String?
    let id: String?
    let user: String?
    let node: String?
    let starttime: Double?
    let endtime: Double?
    /// "OK", an error text, or missing while the task runs.
    let status: String?

    var isRunning: Bool { endtime == nil && (status == nil || status?.uppercased() == "RUNNING") }
    var succeeded: Bool { status?.uppercased() == "OK" }
}

/// One job of `/cluster/backup`. The raw fields are kept so "Back up now" can replay the job's settings.
struct BackupJobDTO: Decodable, Sendable {
    let id: String
    let raw: [String: PVEScalar]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: PVEScalar].self)
        guard let id = raw["id"]?.stringValue else {
            throw DecodingError.keyNotFound(AnyCodingKey("id"), .init(codingPath: decoder.codingPath, debugDescription: "backup job without id"))
        }
        self.id = id
        self.raw = raw
    }

    init(id: String, raw: [String: PVEScalar]) {
        self.id = id
        self.raw = raw
    }

    func string(_ key: String) -> String? { raw[key]?.stringValue }
    func bool(_ key: String) -> Bool { raw[key]?.boolValue ?? false }
    func double(_ key: String) -> Double? { raw[key]?.doubleValue }

    var storage: String? { string("storage") }
    var node: String? { string("node") }
    var comment: String? { string("comment") }
    var schedule: String? { string("schedule") }
    var enabled: Bool { raw["enabled"].map(\.boolValue) ?? true }
    var backsUpAll: Bool { bool("all") }
    var nextRun: Date? { double("next-run").map { Date(timeIntervalSince1970: $0) } }

    /// Guest IDs the job covers (`vmid` is "100,101"). Empty when `all` is set.
    var vmids: Set<Int> {
        Set((string("vmid") ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) })
    }

    /// Settings that `/nodes/{node}/vzdump` understands, for "Back up now".
    static let replayKeys: Set<String> = [
        "vmid", "all", "exclude", "pool", "storage", "mode", "compress", "remove", "mailto", "mailnotification",
        "notes-template", "prune-backups", "protected", "performance", "zstd", "pigz", "bwlimit", "ionice",
        "lockwait", "stopwait", "maxfiles", "exclude-path", "fleecing", "notification-mode",
        "pbs-change-detection-mode", "stdexcludes", "tmpdir", "dumpdir", "script",
    ]

    var replayParameters: [String: String] {
        var params: [String: String] = [:]
        for (key, value) in raw where Self.replayKeys.contains(key) && !value.isEmpty {
            params[key] = value.stringValue
        }
        params["job-id"] = id
        return params
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

struct NotBackedUpDTO: Decodable, Sendable {
    let vmid: Int?
    let name: String?
    let type: String?
}

struct AptUpdateDTO: Decodable, Sendable {
    let package: String?
    let version: String?
    let oldVersion: String?
    let title: String?
    let description: String?
    let priority: String?
    let section: String?
    let origin: String?

    private enum CodingKeys: String, CodingKey {
        case package = "Package", version = "Version", oldVersion = "OldVersion", title = "Title"
        case description = "Description", priority = "Priority", section = "Section", origin = "Origin"
    }
}

struct SyslogLineDTO: Decodable, Sendable {
    let n: Int?
    let t: String?
}

struct TokenCreateDTO: Decodable, Sendable {
    let fullTokenID: String?
    let value: String?

    private enum CodingKeys: String, CodingKey { case fullTokenID = "full-tokenid", value }
}

/// `/access/openid/auth-url` answers with the URL as a plain string.
struct AuthURLDTO: Decodable, Sendable {
    let url: String

    init(from decoder: any Decoder) throws {
        url = try decoder.singleValueContainer().decode(String.self)
    }
}

/// `GET …/snapshot`: `[{name, description, snaptime, vmstate, parent}]`, plus a "current" entry for the live state.
struct SnapshotDTO: Decodable, Sendable {
    let name: String
    let description: String?
    let snaptime: PVEScalar?
    let vmstate: PVEScalar?
    let parent: String?
}
