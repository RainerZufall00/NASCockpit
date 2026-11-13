import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("Snapshot Replication")
struct SnapshotTests {
    @Test func detectsSnapshotsAndReplication() async throws {
        let test = try await TestBackend.connected()
        let capabilities = await test.backend.capabilities()
        #expect(capabilities.isSuperset(of: [.snapshots, .replication]))
    }

    @Test func listsSnapshotsPerShareAndSkipsUnsupportedShares() async throws {
        let test = try await TestBackend.connected()
        let shares = try await test.backend.shareSnapshots()
        #expect(shares.map(\.share) == ["photo"])
        let photo = try #require(shares.first)
        #expect(photo.snapshots.count == 3)
        // Newest first.
        #expect(photo.latest?.id == "GMT+01-2026.11.08-03.00.01")
        #expect(photo.latest?.isScheduled == true)
        let manual = try #require(photo.snapshots.last)
        #expect(manual.description == "Before update")
        #expect(manual.isLocked && manual.isImmutable && !manual.isScheduled)

        let calls = test.transport.calls("SYNO.Core.Share.Snapshot", "list")
        #expect(Set(calls.compactMap { $0.params["name"] }) == ["photo", "home"])
        #expect(calls.allSatisfy { $0.params["limit"] == "-1" })
    }

    @Test func parsesSnapshotNames() throws {
        let date = try #require(DSMMapping.parseSnapshotName("GMT+01-2026.11.08-03.00.01"))
        #expect(date == Date(timeIntervalSince1970: 1_794_103_201))
        let negative = try #require(DSMMapping.parseSnapshotName("GMT-05:30-2026.11.05-10.15.00"))
        #expect(negative == Date(timeIntervalSince1970: 1_793_893_500))
        #expect(DSMMapping.parseSnapshotName("manual-backup") == nil)
    }

    @Test func takeSnapshotSendsSnapinfo() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.takeSnapshot(of: "photo", description: "Before cleanup")
        let call = try #require(test.transport.calls("SYNO.Core.Share.Snapshot", "create").first)
        #expect(call.method == "POST")
        #expect(call.params["name"] == "photo")
        let info = try JSONSerialization.jsonObject(with: Data(try #require(call.params["snapinfo"]).utf8)) as? [String: Any]
        #expect(info?["desc"] as? String == "Before cleanup")
        #expect(info?["lock"] as? Bool == false)
    }

    @Test func mapsReplicationPlans() async throws {
        let test = try await TestBackend.connected()
        let plans = try await test.backend.replicationPlans()
        #expect(plans.map(\.name) == ["docker", "photo", "scans-copy"])

        let photo = try #require(plans.first { $0.id == "p-1" })
        #expect(photo.role == .source)
        #expect(photo.partner == "office-nas")
        #expect(!photo.isSyncing)
        #expect(photo.lastSyncSucceeded == true)
        #expect(photo.lastSync == Date(timeIntervalSince1970: 1_762_560_000))
        #expect(photo.nextSync == Date(timeIntervalSince1970: 1_762_650_000))
        #expect(photo.canSync)

        let docker = try #require(plans.first { $0.id == "p-2" })
        #expect(docker.isSyncing)
        #expect(docker.progress == 0.42)
        #expect(docker.needsAttention)
        #expect(docker.failedSyncCount == 3)
        // Schedule turned off.
        #expect(docker.nextSync == nil)

        let incoming = try #require(plans.first { $0.id == "p-3" })
        #expect(incoming.role == .destination)
        #expect(incoming.partner == "office-nas")
        #expect(!incoming.canSync)
    }

    @Test func syncRepeatsTheEncryptionSetting() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.syncReplication("p-1")
        let call = try #require(test.transport.calls("SYNO.DR.Plan", "sync").first)
        #expect(call.method == "POST")
        #expect(call.params["plan_id"] == "p-1")
        #expect(call.params["nowait"] == "true")
        #expect(call.params["is_send_encrypted"] == "true")
    }

    @Test func permissionDeniedHidesSnapshotAction() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.Share.Snapshot/create": 105]
        let test = try await TestBackend.connected(configuration: configuration)
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.takeSnapshot(of: "photo", description: "")
        }
        #expect(await test.backend.deniedActions().contains(.snapshot))
    }
}
