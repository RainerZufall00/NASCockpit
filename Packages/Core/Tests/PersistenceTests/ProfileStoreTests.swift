import Foundation
import SwiftData
import Testing
import Domain
import Persistence

/// The store as the app wrote it before iCloud sync: unique id, no defaults. Same entity name,
/// so opening the file with the current model runs the real migration.
@Model
final class ServerProfileRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var addresses: [ServerAddress]
    var lastReachedAddressID: UUID?
    var backendRaw: String
    var authMethodRaw: String?
    var username: String
    var pinnedSPKI: String?
    var savesPassword: Bool
    var backgroundRefresh: Bool
    var notifications: NotificationMatrix
    var notifyBackupFailures: Bool?
    var sortOrder: Int
    var colorName: String
    var iconName: String
    var wakeOnLAN: WakeOnLANConfig?

    init(_ profile: ServerProfile) {
        id = profile.id
        name = profile.name
        addresses = profile.addresses
        backendRaw = profile.backend.rawValue
        authMethodRaw = profile.authMethod.rawValue
        username = profile.username
        pinnedSPKI = profile.pinnedSPKI
        savesPassword = profile.savesPassword
        backgroundRefresh = profile.backgroundRefresh
        notifications = profile.notifications
        sortOrder = profile.sortOrder
        colorName = profile.colorName
        iconName = profile.iconName
        wakeOnLAN = profile.wakeOnLAN
    }
}

@MainActor
@Suite("Profile store")
struct ProfileStoreTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ProfileStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func profile(_ name: String, host: String, user: String = "admin", id: UUID = UUID()) -> ServerProfile {
        ServerProfile(id: id, name: name, addresses: [ServerAddress(host: host)], backend: .synology, username: user)
    }

    @Test func profilesFromBeforeSyncSurviveTheMigration() throws {
        let url = try tempDirectory().appending(path: "Profiles.store")
        var nas = profile("Home NAS", host: "192.168.1.10")
        nas.savesPassword = false
        nas.backgroundRefresh = true
        nas.pinnedSPKI = "abc"
        nas.wakeOnLAN = WakeOnLANConfig(mac: try #require(MACAddress("00:11:32:aa:bb:cc")), broadcast: nil)
        do {
            let schema = Schema([ServerProfileRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Profiles", schema: schema, url: url)])
            container.mainContext.insert(ServerProfileRecord(nas))
            try container.mainContext.save()
        }

        let container = try ProfileRepository.makeContainer(url: url)
        let repository = ProfileRepository(container: container, deviceSettings: DeviceProfileSettings(defaults: freshDefaults()))
        let loaded = try #require(repository.all().first)
        #expect(loaded.id == nas.id)
        #expect(loaded.name == "Home NAS")
        #expect(loaded.addresses == nas.addresses)
        #expect(loaded.pinnedSPKI == "abc")
        #expect(loaded.wakeOnLAN == nas.wakeOnLAN)
        // This device's own choices are kept.
        #expect(loaded.savesPassword == false)
        #expect(loaded.backgroundRefresh == true)
    }

    @Test func profileFromAnotherDeviceUsesThisDevicesDefaults() throws {
        let url = try tempDirectory().appending(path: "Profiles.store")
        let container = try ProfileRepository.makeContainer(url: url)
        let defaults = freshDefaults()
        let repository = ProfileRepository(container: container, deviceSettings: DeviceProfileSettings(defaults: defaults))

        // Arrives through iCloud: written into the store, never through this device's repository.
        var remote = profile("Backup", host: "10.0.0.5")
        remote.savesPassword = false
        remote.backgroundRefresh = true
        let context = ModelContext(container)
        context.insert(Persistence.ServerProfileRecord(profile: remote))
        try context.save()

        let loaded = try #require(repository.all().first)
        #expect(loaded.savesPassword == true)
        #expect(loaded.backgroundRefresh == false)

        var changed = loaded
        changed.backgroundRefresh = true
        try repository.upsert(changed)
        #expect(repository.all().first?.backgroundRefresh == true)
    }

    @Test func trustedCertificateNameIsStoredWithThePin() throws {
        let container = try ProfileRepository.makeContainer(inMemory: true)
        let repository = ProfileRepository(container: container, deviceSettings: DeviceProfileSettings(defaults: freshDefaults()))
        var nas = profile("NAS", host: "192.168.1.10")
        nas.pinnedSPKI = "abc"
        nas.trustedCertificateName = "nas.example.com"
        try repository.upsert(nas)
        var loaded = try #require(repository.all().first)
        #expect(loaded.pinnedSPKI == "abc")
        #expect(loaded.trustedCertificateName == "nas.example.com")

        loaded.trustedCertificateName = nil
        try repository.upsert(loaded)
        loaded = try #require(repository.all().first)
        #expect(loaded.pinnedSPKI == "abc")
        #expect(loaded.trustedCertificateName == nil)
    }

    @Test func sameNASAddedOnTwoDevicesMergesIntoOne() throws {
        let container = try ProfileRepository.makeContainer(inMemory: true)
        let repository = ProfileRepository(container: container, deviceSettings: DeviceProfileSettings(defaults: freshDefaults()))
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        var phone = profile("NAS", host: "192.168.1.10", id: high)
        phone.addresses.append(ServerAddress(host: "nas.tail1234.ts.net"))
        try repository.upsert(phone)
        try repository.upsert(profile("My NAS", host: "192.168.1.10", user: "Admin", id: low))
        try repository.upsert(profile("Other", host: "192.168.1.20"))

        let merges = try repository.mergeDuplicates()
        #expect(merges.count == 1)
        #expect(merges.first?.removed == high)
        #expect(merges.first?.kept == low)
        let all = repository.all()
        #expect(all.count == 2)
        let kept = try #require(all.first { $0.id == low })
        #expect(kept.addresses.map(\.host) == ["192.168.1.10", "nas.tail1234.ts.net"])
        #expect(try repository.mergeDuplicates().isEmpty)
    }

    @Test func differentUsersOnTheSameNASStaySeparate() {
        let a = profile("A", host: "nas.local", user: "admin")
        let b = profile("B", host: "nas.local", user: "backup")
        #expect(ProfileDeduplication.merges([a, b]).isEmpty)
    }
}
