import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("Hyper Backup")
struct BackupTests {
    @Test func detectsHyperBackup() async throws {
        let test = try await TestBackend.connected()
        #expect(await test.backend.capabilities().contains(.backup))
    }

    @Test func mapsTasks() async throws {
        let test = try await TestBackend.connected()
        let tasks = try await test.backend.backupTasks()
        #expect(tasks.map(\.name) == ["Archive", "Docker to Office", "Offsite", "USB Photos"])

        let offsite = try #require(tasks.first { $0.id == "3" })
        #expect(offsite.destination == .cloud("Synology C2"))
        #expect(offsite.activity == .idle)
        #expect(offsite.lastResult == .success)
        #expect(offsite.lastBackup == DSMMapping.parseBackupTime("2026/11/08 03:00"))
        #expect(offsite.nextBackup != nil)

        let usb = try #require(tasks.first { $0.id == "5" })
        #expect(usb.destination == .local)
        #expect(usb.activity == .running(progress: 0.37))
        #expect(usb.lastResult == nil)
        #expect(usb.lastBackup != nil)

        let docker = try #require(tasks.first { $0.id == "7" })
        #expect(docker.destination == .remoteNAS)
        #expect(docker.lastResult == .failed)
        #expect(docker.needsAttention)
        #expect(docker.lastBackup == Date(timeIntervalSince1970: 1_762_560_000))

        let archive = try #require(tasks.first { $0.id == "9" })
        #expect(archive.destination == .other("something_new"))
        #expect(archive.activity == .waiting)
        #expect(archive.lastResult == .partial)
    }

    @Test func startAndCancelArePOSTWithTaskID() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.perform(.start, backup: "3")
        try await test.backend.perform(.cancel, backup: "5")
        let start = try #require(test.transport.calls("SYNO.Backup.Task", "backup").first)
        #expect(start.method == "POST")
        #expect(start.params["task_id"] == "3")
        let cancel = try #require(test.transport.calls("SYNO.Backup.Task", "cancel").first)
        #expect(cancel.method == "POST")
        #expect(cancel.params["task_id_list"] == "[5]")
    }

    @Test func reportsDestinationState() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.backupTargetsOffline = ["7"]
        let test = try await TestBackend.connected(configuration: configuration)
        let tasks = try await test.backend.backupTasks()
        #expect(tasks.first { $0.id == "7" }?.targetOnline == false)
        #expect(tasks.first { $0.id == "3" }?.targetOnline == true)
        // Running tasks reach their destination; no check needed.
        #expect(tasks.first { $0.id == "5" }?.targetOnline == true)
        let status = try #require(test.transport.calls("SYNO.Backup.Task", "status").first)
        #expect(status.params["blOnline"] == "true")

        // Cached: polling the list does not contact the destinations again.
        let checks = test.transport.calls("SYNO.Backup.Task", "status").count
        _ = try await test.backend.backupTasks()
        #expect(test.transport.calls("SYNO.Backup.Task", "status").count == checks)
    }

    @Test func startRefusesOfflineDestination() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.backupTargetsOffline = ["3"]
        let test = try await TestBackend.connected(configuration: configuration)
        await #expect(throws: BackendError.backupTargetOffline(task: "Offsite")) {
            try await test.backend.perform(.start, backup: "3")
        }
        #expect(test.transport.calls("SYNO.Backup.Task", "backup").isEmpty)
    }

    @Test func startThatEndsRightAwayIsAnError() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.backupFailsAfterStart = true
        let test = try await TestBackend.connected(configuration: configuration)
        await #expect(throws: BackendError.backupDidNotStart(task: "Offsite")) {
            try await test.backend.perform(.start, backup: "3")
        }
    }

    @Test func readsWakeOnLANFromTheInterfaceTheAppUses() async throws {
        let test = try await TestBackend.connected()
        let config = try #require(await test.backend.wakeOnLANInfo())
        // FakeDSM profiles connect to a host that matches neither interface: the first one with an address wins.
        #expect(config.mac.description == "00:11:32:00:00:02")
        #expect(config.broadcast == "10.255.255.255")

        let info = try JSONDecoder().decode(NetworkInfoDTO.self, from: Data(#"{"nif":[{"addr":"10.0.0.5","mask":"255.0.0.0","mac":"00:11:32:00:00:02"},{"addr":"192.168.1.20","mask":"255.255.255.0","mac":"00-11-32-ab-cd-ef"}]}"#.utf8))
        let matched = try #require(DSMMapping.wakeOnLAN(info, hosts: ["192.168.1.20"]))
        #expect(matched.mac.description == "00:11:32:AB:CD:EF")
        #expect(matched.broadcast == "192.168.1.255")
        #expect(DSMMapping.wakeOnLAN(try JSONDecoder().decode(NetworkInfoDTO.self, from: Data(#"{"nif":[{"mac":""}]}"#.utf8)), hosts: []) == nil)
    }

    @Test func mapsOfflineWords() {
        #expect(DSMMapping.isOfflineWord("target_offline"))
        #expect(DSMMapping.isOfflineWord("Unavailable"))
        #expect(!DSMMapping.isOfflineWord("backupable"))
        #expect(!DSMMapping.isOfflineWord("none"))
    }

    @Test func permissionDeniedHidesTheAction() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Backup.Task/backup": 105]
        let test = try await TestBackend.connected(configuration: configuration)
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.perform(.start, backup: "3")
        }
        #expect(await test.backend.deniedActions().contains(.backupControl))
    }

    @Test func mapsStatusWords() {
        #expect(DSMMapping.backupActivity(status: "detect", state: nil, lastResult: nil, progress: nil) == .maintenance)
        #expect(DSMMapping.backupActivity(status: "none", state: "suspended", lastResult: nil, progress: nil) == .suspended)
        #expect(DSMMapping.backupActivity(status: "none", state: "backupable", lastResult: "done", progress: nil) == .idle)
        #expect(DSMMapping.backupResult("cancel") == .cancelled)
        #expect(DSMMapping.backupResult("none") == nil)
        #expect(DSMMapping.backupDestination("image:image_remote rsync") == .remoteNAS)
        #expect(DSMMapping.backupDestination("cloud_s3") == .cloud("S3"))
    }
}
