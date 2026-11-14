import Foundation
import Testing
import Domain
@testable import DemoBackend

@Suite("Demo backend")
struct MockBackendTests {
    @Test func offlineDemoServerFails() async {
        let spec = DemoData.spec(for: DemoData.backupID)!
        let backend = MockBackend(spec: spec, latency: .zero)
        await #expect(throws: BackendError.unreachable) { try await backend.connect(otp: nil) }
    }

    @Test func requiresConnection() async {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero)
        await #expect(throws: BackendError.notConnected) { try await backend.systemSnapshot() }
    }

    @Test func updatesIncludeDSMWhenAvailable() async throws {
        let backend = MockBackend(spec: DemoData.spec(for: DemoData.officeID)!, latency: .zero, startConnected: true)
        let updates = try await backend.updates()
        #expect(updates.first?.isSystemUpdate == true)
        #expect(updates.count == 4)
    }

    @Test func logsPaginateAndFilter() async throws {
        let backend = MockBackend.preview()
        let first = try await backend.logs(LogQuery(offset: 0, limit: 50))
        #expect(first.entries.count == 50)
        #expect(first.nextOffset == 50)

        let errors = try await backend.logs(LogQuery(offset: 0, limit: 500, levels: [.error]))
        #expect(errors.entries.allSatisfy { $0.level == .error })
        #expect(!errors.entries.isEmpty)

        let search = try await backend.logs(LogQuery(keyword: "hyper backup"))
        #expect(search.entries.allSatisfy { $0.message.localizedCaseInsensitiveContains("hyper backup") })
    }

    @Test func snapshotValuesStayInRange() async throws {
        let snapshot = try await MockBackend.preview().systemSnapshot()
        let cpu = try #require(snapshot.cpuLoad)
        let memory = try #require(snapshot.memoryUsage)
        #expect((0...1).contains(cpu))
        #expect((0...1).contains(memory))
    }

    // MARK: Phase 2 writes

    private func office() -> MockBackend {
        MockBackend(spec: DemoData.spec(for: DemoData.officeID)!, latency: .zero, startConnected: true, actionDuration: 0)
    }

    @Test func packageUpdateClearsTheUpdate() async throws {
        let backend = office()
        try await backend.installPackageUpdate("SynologyDrive") { _ in }
        let drive = try #require(try await backend.installedPackages().first { $0.id == "SynologyDrive" })
        #expect(drive.version == "3.5.1-26102")
        #expect(!drive.hasUpdate)
        #expect(try await backend.updates().count == 3)
    }

    @Test func systemUpdateRestartsAndReconnects() async throws {
        let backend = office()
        let events = backend.events
        let collector = Task {
            var states: [ConnectionState] = []
            for await event in events {
                if case .state(let state) = event { states.append(state) }
                if states.last == .connected { break }
            }
            return states
        }
        try await backend.installSystemUpdate { _ in }
        #expect(await collector.value == [.rebooting, .connected])
        #expect(try await backend.updates().contains { $0.isSystemUpdate } == false)
        #expect(try await backend.systemSnapshot().osVersion == "DSM 7.2.2-72806 Update 3")
    }

    @Test func containerAndProjectActionsChangeState() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 0)
        #expect(try await backend.composeProjects().first?.status == .partial)

        try await backend.perform(.start, project: "smarthome")
        #expect(try await backend.composeProjects().first?.status == .running)

        try await backend.perform(.stop, container: "jellyfin")
        let jellyfin = try #require(try await backend.containers().first { $0.name == "jellyfin" })
        #expect(!jellyfin.status.isRunning)
        #expect(!jellyfin.hasFailed)
    }

    @Test func failedContainerLogShowsError() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true)
        let lines = try await backend.containerLogs("zigbee2mqtt", limit: 50)
        #expect(lines.first?.stream == "stderr")
    }

    @Test func moveCarriesSubfoldersAndCopyKeepsSource() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 0)
        try await backend.transfer("/photo/2025", to: "/home/Archive", mode: .move) { _ in }
        #expect(try await backend.folderContents("/photo").contains { $0.name == "2025" } == false)
        #expect(try await backend.folderContents("/home/Archive/2025").map(\.name).contains("Summer"))

        try await backend.transfer("/home/Notes.txt", to: "/docker", mode: .copy) { _ in }
        #expect(try await backend.folderContents("/home").contains { $0.name == "Notes.txt" })
        #expect(try await backend.folderContents("/docker").contains { $0.name == "Notes.txt" })
    }

    @Test func demoNeverDisablesTheAppAccount() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 0)
        await #expect(throws: BackendError.self) { try await backend.setUser("nas-admin", disabled: true) }
        try await backend.setUser("anna", disabled: true)
        #expect(try await backend.users().first { $0.name == "anna" }?.isDisabled == true)
    }

    @Test func demoBackupRunsAndCancels() async throws {
        // Real step timing so the simulated run is still busy when we look.
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 1)
        try await backend.perform(.start, backup: "1")
        var task = try #require(try await backend.backupTasks().first { $0.id == "1" })
        #expect(task.activity.isBusy)
        try await backend.perform(.cancel, backup: "1")
        task = try #require(try await backend.backupTasks().first { $0.id == "1" })
        #expect(task.activity == .idle)
        #expect(task.lastResult == .cancelled)
    }

    @Test func demoLogsBySource() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 0)
        let connections = try await backend.logs(LogQuery(source: .connection, limit: 500))
        #expect(!connections.entries.isEmpty && connections.entries.allSatisfy { $0.category == "Connection" })
        let system = try await backend.logs(LogQuery(source: .system, limit: 500))
        #expect(system.entries.allSatisfy { $0.category != "Connection" })
        let backup = try await backend.logs(LogQuery(source: .backup, limit: 500, backupTask: "Docker configs"))
        #expect(!backup.entries.isEmpty && backup.entries.allSatisfy { $0.category == "Docker configs" })
        #expect(backup.entries.contains { $0.level == .error })
    }

    @Test func demoSnapshotAndReplication() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 1)
        let before = try #require(try await backend.shareSnapshots().first { $0.share == "media" })
        #expect(before.snapshots.isEmpty)
        try await backend.takeSnapshot(of: "media", description: "Test")
        let after = try #require(try await backend.shareSnapshots().first { $0.share == "media" })
        #expect(after.latest?.description == "Test")

        try await backend.syncReplication("plan-photo")
        #expect(try await backend.replicationPlans().first { $0.id == "plan-photo" }?.isSyncing == true)
    }

    @Test func demoSecurityScan() async throws {
        let backend = MockBackend(spec: DemoData.servers[0], latency: .zero, startConnected: true, actionDuration: 1)
        let before = try await backend.securityReport()
        #expect(before.hasBeenScanned && !before.isScanning)
        #expect(before.issueCount == 2)
        #expect(before.findings.first?.severity == .warning)

        try await backend.startSecurityScan()
        let running = try await backend.securityReport()
        #expect(running.isScanning)
        #expect(running.progress == 0)
    }

    @Test func proxmoxHasNoSecurityAdvisor() async throws {
        let backend = MockBackend(spec: DemoData.spec(for: DemoData.proxmoxID)!, latency: .zero, startConnected: true)
        await #expect(throws: BackendError.notSupported) { try await backend.securityReport() }
    }
}
