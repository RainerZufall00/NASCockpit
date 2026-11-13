import Foundation
import SwiftData
import Domain

/// SwiftData record for a server profile. Synced through the private iCloud database when iCloud sync is on.
///
/// CloudKit rules: no unique constraints, every property has a default or is optional.
/// Everything that says where a NAS is or who signs in is end-to-end encrypted (`allowsCloudEncryption`).
/// Passwords and tokens are never here; they stay in this device's Keychain.
/// `savesPassword` and `backgroundRefresh` are per device: `DeviceProfileSettings` overrides them.
@Model
public final class ServerProfileRecord {
    public var id: UUID = UUID()
    @Attribute(.allowsCloudEncryption) public var name: String = ""
    @Attribute(.allowsCloudEncryption) public var addresses: [ServerAddress] = []
    public var lastReachedAddressID: UUID?
    public var backendRaw: String = BackendKind.synology.rawValue
    /// Optional so stores written before this existed migrate without a schema version; `nil` means password.
    public var authMethodRaw: String?
    @Attribute(.allowsCloudEncryption) public var username: String = ""
    @Attribute(.allowsCloudEncryption) public var pinnedSPKI: String?
    public var savesPassword: Bool = true
    public var backgroundRefresh: Bool = false
    public var notifications: NotificationMatrix = NotificationMatrix()
    /// Optional so stores written before this existed migrate without a schema version; `nil` means on.
    public var notifyBackupFailures: Bool?
    public var sortOrder: Int = 0
    public var colorName: String = "blue"
    public var iconName: String = "externaldrive.connected.to.line.below"
    /// Optional, added later; `nil` means not set up.
    @Attribute(.allowsCloudEncryption) public var wakeOnLAN: WakeOnLANConfig?

    public init(profile: ServerProfile) {
        id = profile.id
        name = profile.name
        addresses = profile.addresses
        lastReachedAddressID = profile.lastReachedAddressID
        backendRaw = profile.backend.rawValue
        authMethodRaw = profile.authMethod.rawValue
        username = profile.username
        pinnedSPKI = profile.pinnedSPKI
        savesPassword = profile.savesPassword
        backgroundRefresh = profile.backgroundRefresh
        notifications = profile.notifications
        notifyBackupFailures = profile.notifyBackupFailures
        sortOrder = profile.sortOrder
        colorName = profile.colorName
        iconName = profile.iconName
        wakeOnLAN = profile.wakeOnLAN
    }

    public func update(from profile: ServerProfile) {
        name = profile.name
        addresses = profile.addresses
        lastReachedAddressID = profile.lastReachedAddressID
        backendRaw = profile.backend.rawValue
        authMethodRaw = profile.authMethod.rawValue
        username = profile.username
        pinnedSPKI = profile.pinnedSPKI
        savesPassword = profile.savesPassword
        backgroundRefresh = profile.backgroundRefresh
        notifications = profile.notifications
        notifyBackupFailures = profile.notifyBackupFailures
        sortOrder = profile.sortOrder
        colorName = profile.colorName
        iconName = profile.iconName
        wakeOnLAN = profile.wakeOnLAN
    }

    public var profile: ServerProfile {
        ServerProfile(
            id: id,
            name: name,
            addresses: addresses,
            lastReachedAddressID: lastReachedAddressID,
            backend: BackendKind(rawValue: backendRaw) ?? .synology,
            authMethod: authMethodRaw.map(AuthMethod.init(rawValue:)) ?? .password,
            username: username,
            pinnedSPKI: pinnedSPKI,
            savesPassword: savesPassword,
            backgroundRefresh: backgroundRefresh,
            notifications: notifications,
            notifyBackupFailures: notifyBackupFailures ?? true,
            sortOrder: sortOrder,
            colorName: colorName,
            iconName: iconName,
            wakeOnLAN: wakeOnLAN
        )
    }
}

/// Settings that belong to one device and must not sync: whether this device keeps the password,
/// and whether this device refreshes in the background (that needs a Keychain copy that only exists here).
public struct DeviceProfileSettings: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var savesPassword: Bool
        public var backgroundRefresh: Bool
    }

    private static let key = "deviceProfileSettings"
    private static let importedKey = "deviceProfileSettingsImported"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A profile that arrives from another device: the password is kept once entered, no background refresh.
    public static let newDevice = Entry(savesPassword: true, backgroundRefresh: false)

    public var all: [String: Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    public func entry(for id: ServerID) -> Entry? { all[id.uuidString] }

    public func set(_ entry: Entry?, for id: ServerID) {
        var values = all
        values[id.uuidString] = entry
        defaults.set(try? JSONEncoder().encode(values), forKey: Self.key)
    }

    var didImport: Bool {
        get { defaults.bool(forKey: Self.importedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.importedKey) }
    }
}

/// Whether the profiles sync through iCloud. Read once when the store opens.
public enum ProfileSync {
    private static let key = "iCloudSyncEnabled"
    public static let containerIdentifier = "iCloud.com.nascockpit.app"

    /// On unless the user turned it off.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@MainActor
public final class ProfileRepository {
    private let container: ModelContainer
    private let deviceSettings: DeviceProfileSettings

    public init(container: ModelContainer, deviceSettings: DeviceProfileSettings = DeviceProfileSettings()) {
        self.container = container
        self.deviceSettings = deviceSettings
        importDeviceSettings()
    }

    /// `url` is for tests; the app uses the default location.
    public static func makeContainer(inMemory: Bool = false, cloudSync: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([ServerProfileRecord.self])
        let cloud: ModelConfiguration.CloudKitDatabase = cloudSync && !inMemory ? .private(ProfileSync.containerIdentifier) : .none
        let configuration = if let url {
            ModelConfiguration("Profiles", schema: schema, url: url, cloudKitDatabase: cloud)
        } else {
            ModelConfiguration("Profiles", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: cloud)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A new context per call, so changes that iCloud imported in the background are always seen.
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    public func all() -> [ServerProfile] {
        records(in: makeContext()).map(profile(from:))
    }

    public func upsert(_ profile: ServerProfile) throws {
        let context = makeContext()
        let existing = try records(in: context, id: profile.id)
        if let record = existing.first {
            record.update(from: profile)
            // CloudKit can deliver the same record twice; keep one.
            existing.dropFirst().forEach(context.delete)
        } else {
            context.insert(ServerProfileRecord(profile: profile))
        }
        try context.save()
        deviceSettings.set(.init(savesPassword: profile.savesPassword, backgroundRefresh: profile.backgroundRefresh), for: profile.id)
    }

    public func delete(_ id: ServerID) throws {
        let context = makeContext()
        let existing = try records(in: context, id: id)
        if !existing.isEmpty {
            existing.forEach(context.delete)
            try context.save()
        }
        deviceSettings.set(nil, for: id)
    }

    /// The same NAS added on two devices before sync was on. Both devices pick the same survivor
    /// (smallest UUID), so they never delete each other's copy. Returns what was merged into what.
    public func mergeDuplicates() throws -> [(removed: ServerID, kept: ServerID)] {
        let context = makeContext()
        let all = records(in: context)
        let merges = ProfileDeduplication.merges(all.map(\.profile))
        guard !merges.isEmpty else { return [] }
        for merge in merges {
            guard let kept = all.first(where: { $0.id == merge.kept }) else { continue }
            var profile = kept.profile
            for removed in all where removed.id == merge.removed {
                profile.addresses = ProfileDeduplication.union(profile.addresses, removed.addresses)
                context.delete(removed)
            }
            if profile.addresses != kept.addresses { kept.addresses = profile.addresses }
            if deviceSettings.entry(for: merge.kept) == nil, let entry = deviceSettings.entry(for: merge.removed) {
                deviceSettings.set(entry, for: merge.kept)
            }
            deviceSettings.set(nil, for: merge.removed)
        }
        try context.save()
        return merges
    }

    private func profile(from record: ServerProfileRecord) -> ServerProfile {
        var profile = record.profile
        let entry = deviceSettings.entry(for: record.id) ?? DeviceProfileSettings.newDevice
        profile.savesPassword = entry.savesPassword
        profile.backgroundRefresh = entry.backgroundRefresh
        return profile
    }

    /// Once: the profiles that were on this device before iCloud sync keep their own settings.
    private func importDeviceSettings() {
        guard !deviceSettings.didImport else { return }
        for record in records(in: makeContext()) where deviceSettings.entry(for: record.id) == nil {
            deviceSettings.set(.init(savesPassword: record.savesPassword, backgroundRefresh: record.backgroundRefresh), for: record.id)
        }
        deviceSettings.didImport = true
    }

    private func records(in context: ModelContext) -> [ServerProfileRecord] {
        let descriptor = FetchDescriptor<ServerProfileRecord>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)])
        let records = (try? context.fetch(descriptor)) ?? []
        // A record that CloudKit delivered twice shows once.
        var seen = Set<UUID>()
        return records.filter { seen.insert($0.id).inserted }
    }

    private func records(in context: ModelContext, id: ServerID) throws -> [ServerProfileRecord] {
        try context.fetch(FetchDescriptor<ServerProfileRecord>(predicate: #Predicate { $0.id == id }))
    }
}
