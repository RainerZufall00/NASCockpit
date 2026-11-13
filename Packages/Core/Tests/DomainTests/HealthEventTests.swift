import Foundation
import Testing
@testable import Domain

@Suite("Health event detection")
struct HealthEventTests {
    let server = UUID()

    func snapshot(volumeStatus: HealthStatus = .normal, used: Int64 = 50, diskStatus: HealthStatus = .normal) -> SystemSnapshot {
        SystemSnapshot(
            model: "DS923+",
            osVersion: "DSM 7.2",
            volumes: [VolumeInfo(id: "volume_1", name: "Volume 1", status: volumeStatus, totalBytes: 100, usedBytes: used)],
            disks: [DiskInfo(id: "sda", name: "Drive 1", status: diskStatus)]
        )
    }

    func package(_ id: String, _ version: String) -> UpdateItem {
        UpdateItem(serverID: server, kind: .package(id: id), name: id, installedVersion: "1", availableVersion: version, requiresReboot: false)
    }

    func system(_ version: String) -> UpdateItem {
        UpdateItem(serverID: server, kind: .system, name: "DSM", installedVersion: nil, availableVersion: version, requiresReboot: true)
    }

    @Test func firstRunReportsStorageButNoUpdatesOrContainers() {
        let result = HealthEventDetector.evaluate(
            previous: nil,
            snapshot: snapshot(volumeStatus: .degraded),
            updates: [package("Docker", "2"), system("7.2.2")],
            containers: [ContainerItem(name: "web", status: .exited, exitCode: 1)]
        )
        #expect(result.events == [.storageProblems([.volume(name: "Volume 1", status: .degraded)])])
        #expect(result.state.knownPackageUpdates == ["Docker@2"])
        #expect(result.state.knownSystemVersion == "7.2.2")
    }

    @Test func storageProblemReportsOncePerProblemAndAgainAfterRelapse() {
        let first = HealthEventDetector.evaluate(previous: HealthState(), snapshot: snapshot(used: 95, diskStatus: .warning), updates: nil, containers: nil)
        #expect(first.events == [.storageProblems([.disk(name: "Drive 1", status: .warning), .volumeFull(name: "Volume 1", usage: 0.95)])])

        let second = HealthEventDetector.evaluate(previous: first.state, snapshot: snapshot(used: 96, diskStatus: .warning), updates: nil, containers: nil)
        #expect(second.events.isEmpty)

        let fixed = HealthEventDetector.evaluate(previous: second.state, snapshot: snapshot(), updates: nil, containers: nil)
        #expect(fixed.events.isEmpty)
        #expect(fixed.state.storageProblems.isEmpty)

        let relapse = HealthEventDetector.evaluate(previous: fixed.state, snapshot: snapshot(used: 95), updates: nil, containers: nil)
        #expect(relapse.events == [.storageProblems([.volumeFull(name: "Volume 1", usage: 0.95)])])
    }

    @Test func onlyUnknownUpdatesAreReported() {
        let baseline = HealthEventDetector.evaluate(previous: HealthState(), snapshot: nil, updates: [package("Docker", "2")], containers: nil)
        #expect(baseline.events == [.packageUpdates(["Docker"])])

        let next = HealthEventDetector.evaluate(previous: baseline.state, snapshot: nil, updates: [package("Docker", "2"), package("Plex", "5"), system("7.2.2")], containers: nil)
        #expect(next.events == [.packageUpdates(["Plex"]), .systemUpdate(version: "7.2.2")])

        let same = HealthEventDetector.evaluate(previous: next.state, snapshot: nil, updates: [package("Docker", "2"), package("Plex", "5"), system("7.2.2")], containers: nil)
        #expect(same.events.isEmpty)

        // A newer version of a known package is a new update.
        let newer = HealthEventDetector.evaluate(previous: same.state, snapshot: nil, updates: [package("Docker", "3")], containers: nil)
        #expect(newer.events == [.packageUpdates(["Docker"])])
        // The DSM version is remembered after installing it.
        #expect(newer.state.knownSystemVersion == "7.2.2")
    }

    @Test func containerFailureNeedsAPreviousRunAndANonZeroExitCode() {
        let running = HealthState(runningContainers: ["web", "db", "job"])
        let result = HealthEventDetector.evaluate(previous: running, snapshot: nil, updates: nil, containers: [
            ContainerItem(name: "web", status: .exited, exitCode: 137),
            ContainerItem(name: "db", status: .stopped, exitCode: 0),
            ContainerItem(name: "job", status: .running),
            ContainerItem(name: "old", status: .exited, exitCode: 1),
        ])
        #expect(result.events == [.containerFailed(name: "web", exitCode: 137)])

        // Still down: no second report.
        let again = HealthEventDetector.evaluate(previous: result.state, snapshot: nil, updates: nil, containers: [
            ContainerItem(name: "web", status: .exited, exitCode: 137),
        ])
        #expect(again.events.isEmpty)

        // Runs again, fails again: a new incident.
        let recovered = HealthEventDetector.evaluate(previous: again.state, snapshot: nil, updates: nil, containers: [ContainerItem(name: "web", status: .running)])
        let failedAgain = HealthEventDetector.evaluate(previous: recovered.state, snapshot: nil, updates: nil, containers: [ContainerItem(name: "web", status: .exited, exitCode: 1)])
        #expect(failedAgain.events == [.containerFailed(name: "web", exitCode: 1)])
    }

    @Test func backupFailureReportsOncePerRun() {
        let day1 = Date(timeIntervalSince1970: 1_000)
        let day2 = Date(timeIntervalSince1970: 90_000)
        func task(_ result: BackupResult, _ date: Date) -> BackupTask {
            BackupTask(id: "1", name: "Nightly", destination: .local, lastResult: result, lastBackup: date)
        }
        let first = HealthEventDetector.evaluate(previous: HealthState(), snapshot: nil, updates: nil, containers: nil, backups: [task(.failed, day1)])
        #expect(first.events == [.backupFailed(task: "Nightly", partial: false)])

        let same = HealthEventDetector.evaluate(previous: first.state, snapshot: nil, updates: nil, containers: nil, backups: [task(.failed, day1)])
        #expect(same.events.isEmpty)

        // The next run ended with skipped files: a new incident.
        let next = HealthEventDetector.evaluate(previous: same.state, snapshot: nil, updates: nil, containers: nil, backups: [task(.partial, day2)])
        #expect(next.events == [.backupFailed(task: "Nightly", partial: true)])

        let fine = HealthEventDetector.evaluate(previous: next.state, snapshot: nil, updates: nil, containers: nil, backups: [task(.success, day2)])
        #expect(fine.events.isEmpty)
        #expect(fine.state.failedBackups.isEmpty)
    }

    @Test func volumeThresholdIsAdjustable() {
        let result = HealthEventDetector.evaluate(previous: HealthState(), snapshot: snapshot(used: 85), updates: nil, containers: nil, volumeFullThreshold: 0.8)
        #expect(result.events == [.storageProblems([.volumeFull(name: "Volume 1", usage: 0.85)])])
        #expect(HealthEventDetector.evaluate(previous: HealthState(), snapshot: snapshot(used: 85), updates: nil, containers: nil).events.isEmpty)
    }

    @Test func backupToggleLivesOnTheProfile() {
        var profile = ServerProfile(name: "NAS", addresses: [], username: "admin")
        #expect(profile.allowsNotification(for: .backupFailed(task: "a", partial: false)))
        profile.notifyBackupFailures = false
        #expect(!profile.allowsNotification(for: .backupFailed(task: "a", partial: false)))
        #expect(profile.allowsNotification(for: .packageUpdates(["a"])))
    }

    @Test func missingInputsKeepTheirState() {
        let state = HealthState(storageProblems: ["x"], knownPackageUpdates: ["a@1"], knownSystemVersion: "7", runningContainers: ["web"])
        let result = HealthEventDetector.evaluate(previous: state, snapshot: nil, updates: nil, containers: nil)
        #expect(result.state == state)
        #expect(result.events.isEmpty)
    }

    @Test func matrixFiltersByType() {
        let matrix = NotificationMatrix(storageProblems: false, packageUpdates: true, systemUpdates: false, containerFailures: true)
        #expect(!matrix.allows(.storageProblems([])))
        #expect(matrix.allows(.packageUpdates(["a"])))
        #expect(!matrix.allows(.systemUpdate(version: "1")))
        #expect(matrix.allows(.containerFailed(name: "a", exitCode: 1)))
    }
}
