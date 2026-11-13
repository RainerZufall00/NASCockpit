import Foundation
import Domain

public enum SharedStorage {
    /// App group shared by the app and the widget extension (see the entitlements of both targets).
    public static let appGroup = "group.com.nascockpit.shared"
}

/// Last known status per NAS – for the overview's warm start and the widgets.
/// Contains no hosts, user names or credentials.
public struct CachedServerStatus: Codable, Sendable, Hashable {
    public var serverID: ServerID
    public var name: String
    public var snapshot: SystemSnapshot?
    public var pendingUpdates: Int?
    public var lastReached: Date?
    public var updatedAt: Date
    public var needsLogin: Bool
    /// For the widgets. Optional so caches written by older versions still decode.
    public var iconName: String?
    public var colorName: String?

    public init(serverID: ServerID, name: String, snapshot: SystemSnapshot?, pendingUpdates: Int?, lastReached: Date?, updatedAt: Date = .now, needsLogin: Bool = false, iconName: String? = nil, colorName: String? = nil) {
        self.serverID = serverID
        self.name = name
        self.snapshot = snapshot
        self.pendingUpdates = pendingUpdates
        self.lastReached = lastReached
        self.updatedAt = updatedAt
        self.needsLogin = needsLogin
        self.iconName = iconName
        self.colorName = colorName
    }
}

public actor StatusCache {
    private let url: URL
    private var cache: [ServerID: CachedServerStatus]?

    /// Uses the app-group container when available (needed for widgets), else Application Support.
    public init(appGroupIdentifier: String? = nil, fileName: String = "status-cache.json") {
        let base = appGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        } ?? URL.applicationSupportDirectory
        url = base.appending(path: fileName)
    }

    public func load() -> [ServerID: CachedServerStatus] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url)).flatMap {
            try? Self.decoder.decode([ServerID: CachedServerStatus].self, from: $0)
        } ?? [:]
        cache = loaded
        return loaded
    }

    public func update(_ status: CachedServerStatus) {
        var all = load()
        all[status.serverID] = status
        write(all)
    }

    public func remove(_ id: ServerID) {
        var all = load()
        all[id] = nil
        write(all)
    }

    private func write(_ all: [ServerID: CachedServerStatus]) {
        cache = all
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(all)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The cache is best effort; a failed write only costs the warm start.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
