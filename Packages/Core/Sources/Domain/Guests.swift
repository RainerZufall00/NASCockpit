import Foundation

// Virtual machines and containers of a hypervisor (Proxmox VE). Platform-neutral.

public enum GuestKind: String, Sendable, Hashable, Codable {
    /// Full virtual machine (Proxmox: QEMU/KVM).
    case virtualMachine
    /// System container (Proxmox: LXC).
    case container
}

public enum GuestStatus: String, Sendable, Hashable, Codable {
    case running, stopped, paused, suspended, unknown

    public var isRunning: Bool { self == .running }
}

public struct VirtualGuest: Identifiable, Sendable, Hashable, Codable {
    /// Stable across nodes: "qemu/100", "lxc/101".
    public var id: String
    public var vmid: Int
    public var name: String
    public var node: String
    public var kind: GuestKind
    public var status: GuestStatus
    /// 0…1 of the guest's own cores.
    public var cpuLoad: Double?
    public var cores: Int?
    public var memoryBytes: Int64?
    public var maxMemoryBytes: Int64?
    public var diskBytes: Int64?
    public var maxDiskBytes: Int64?
    public var uptime: TimeInterval?
    public var isTemplate: Bool
    /// Set while a task (backup, migration, snapshot…) holds the guest.
    public var lock: String?
    public var haState: String?
    public var tags: [String]

    public init(
        id: String, vmid: Int, name: String, node: String, kind: GuestKind, status: GuestStatus,
        cpuLoad: Double? = nil, cores: Int? = nil, memoryBytes: Int64? = nil, maxMemoryBytes: Int64? = nil,
        diskBytes: Int64? = nil, maxDiskBytes: Int64? = nil, uptime: TimeInterval? = nil,
        isTemplate: Bool = false, lock: String? = nil, haState: String? = nil, tags: [String] = []
    ) {
        self.id = id
        self.vmid = vmid
        self.name = name
        self.node = node
        self.kind = kind
        self.status = status
        self.cpuLoad = cpuLoad
        self.cores = cores
        self.memoryBytes = memoryBytes
        self.maxMemoryBytes = maxMemoryBytes
        self.diskBytes = diskBytes
        self.maxDiskBytes = maxDiskBytes
        self.uptime = uptime
        self.isTemplate = isTemplate
        self.lock = lock
        self.haState = haState
        self.tags = tags
    }

    public var memoryUsage: Double? {
        guard let memoryBytes, let maxMemoryBytes, maxMemoryBytes > 0 else { return nil }
        return min(1, Double(memoryBytes) / Double(maxMemoryBytes))
    }

    /// Templates and locked guests cannot be started or stopped.
    public var canControl: Bool { !isTemplate && lock == nil }
}

public enum GuestAction: String, Sendable, Hashable, CaseIterable {
    /// Start a stopped guest.
    case start
    /// Ask the guest OS to shut down (ACPI / init). Fails if the guest ignores it.
    case shutdown
    /// Power off immediately, like pulling the plug.
    case stop
    /// Shut down and start again.
    case reboot

    /// Actions that make sense for the current state.
    public static func available(for guest: VirtualGuest) -> [GuestAction] {
        guard guest.canControl else { return [] }
        switch guest.status {
        case .running: return [.shutdown, .reboot, .stop]
        case .paused, .suspended: return [.start, .stop]
        case .stopped: return [.start]
        case .unknown: return []
        }
    }
}

/// Builds the link that hands a shell to an external terminal app (WebSSH, Termius, Blink, …).
/// Most of them register the `ssh://` scheme; a custom template covers the rest.
public enum SSHLink {
    public static let defaultTemplate = "ssh://{user}@{host}:{port}"
    public static let defaultUser = "root"
    public static let defaultPort = 22

    public static let templateKey = "ssh.template"
    public static let userKey = "ssh.user"
    public static let portKey = "ssh.port"

    /// Placeholders: `{user}`, `{host}`, `{port}`. Values are percent-encoded for a URL.
    public static func url(host: String, user: String, port: Int, template: String) -> URL? {
        func escape(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
        }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let text = template
            .replacingOccurrences(of: "{user}", with: escape(user))
            .replacingOccurrences(of: "{host}", with: bracketed.hasPrefix("[") ? bracketed : escape(bracketed))
            .replacingOccurrences(of: "{port}", with: String(port))
        return URL(string: text)
    }

    /// The user's settings (app-wide), falling back to `root` on port 22 with the `ssh://` scheme.
    public static func url(host: String, defaults: UserDefaults = .standard) -> URL? {
        let template = defaults.string(forKey: templateKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultTemplate
        let user = defaults.string(forKey: userKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultUser
        let port = defaults.object(forKey: portKey) as? Int ?? defaultPort
        return url(host: host, user: user, port: port, template: template)
    }
}

/// The command that opens a root shell in a Proxmox container from an SSH session on the host.
/// `pct enter` needs no SSH server and no password inside the container.
public enum HostShellCommand {
    /// `pct enter 105`; `sudo` for a non-root SSH user; through `ssh -t <node>` when the container runs on
    /// another cluster node (cluster nodes trust each other's root key).
    public static func enterContainer(vmid: Int, guestNode: String, hostNode: String?, user: String) -> String {
        var command = "pct enter \(vmid)"
        if let hostNode, !guestNode.isEmpty, guestNode != hostNode {
            command = "ssh -t \(guestNode) \(command)"
        }
        return user == "root" ? command : "sudo \(command)"
    }

    /// Updates every package of the host, the way the Proxmox docs recommend (`full-upgrade`, not `upgrade`).
    public static func upgradeHost(user: String) -> String {
        user == "root" ? "apt update && apt full-upgrade" : "sudo apt update && sudo apt full-upgrade"
    }

    /// The SSH user from Settings → Terminal App.
    public static func sshUser(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: SSHLink.userKey).flatMap { $0.isEmpty ? nil : $0 } ?? SSHLink.defaultUser
    }
}

/// A snapshot of a VM or container.
public struct GuestSnapshot: Identifiable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var date: Date?
    /// VM snapshot with RAM: rolling back resumes the running VM.
    public var includesMemory: Bool
    public var parent: String?

    public var id: String { name }

    public init(name: String, description: String = "", date: Date? = nil, includesMemory: Bool = false, parent: String? = nil) {
        self.name = name
        self.description = description
        self.date = date
        self.includesMemory = includesMemory
        self.parent = parent
    }
}

public enum GuestSnapshotAction: String, Sendable, Hashable {
    case create, rollback, delete
}

/// Proxmox snapshot names: a letter first, then letters, digits, "_" or "-", at most 40 characters.
public enum GuestSnapshotName {
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count >= 2, name.count <= 40,
              CharacterSet.letters.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// "before_update_20261111_0907"
    public static func suggested(prefix: String = "before_update", date: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%@_%04d%02d%02d_%02d%02d", prefix, c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
