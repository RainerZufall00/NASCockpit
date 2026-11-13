import Foundation
import Synchronization
import Testing
import Domain
import Networking
@testable import SynologyBackend

/// Collects progress callbacks.
final class ProgressRecorder: Sendable {
    private let values = Mutex<[Double?]>([])
    var all: [Double?] { values.withLock { $0 } }

    var handler: ProgressHandler {
        { [self] value in values.withLock { $0.append(value) } }
    }
}

@Suite("DSM writes")
struct WriteTests {
    @Test func packageUpdateDownloadsThenUpgradesLikePackageCenter() async throws {
        let test = try await TestBackend.connected()
        let progress = ProgressRecorder()
        try await test.backend.installPackageUpdate("ContainerManager", progress: progress.handler)

        let download = try #require(test.transport.calls("SYNO.Core.Package.Installation", "install").first)
        #expect(download.method == "POST")
        #expect(download.params["name"] == "ContainerManager")
        #expect(download.params["url"]?.hasSuffix("ContainerManager-x86_64-24.0.2-1541.spk") == true)
        #expect(download.params["checksum"] == "0123456789abcdef0123456789abcdef")
        #expect(download.params["filesize"] == "104857600")
        #expect(download.params["operation"] == "upgrade")

        let upgrade = try #require(test.transport.calls("SYNO.Core.Package.Installation", "upgrade").first)
        #expect(upgrade.method == "POST")
        #expect(upgrade.params["task_id"] == "@SYNOPKG_DOWNLOAD_ContainerManager")
        #expect(upgrade.params["name"] == nil)

        let polls = test.transport.calls("SYNO.Core.Package.Installation", "status").map { $0.params["task_id"] }
        #expect(polls == Array(repeating: "@SYNOPKG_DOWNLOAD_ContainerManager", count: 3) + Array(repeating: "@SYNOPKG_UPGRADE_1", count: 3))
        let values = progress.all.compactMap { $0 }
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test func packageWithoutDownloadLinkUsesTheShortcut() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.installPackageUpdate("HyperBackup", progress: { _ in })
        #expect(test.transport.calls("SYNO.Core.Package.Installation", "install").isEmpty)
        let upgrade = try #require(test.transport.calls("SYNO.Core.Package.Installation", "upgrade").first)
        #expect(upgrade.params["name"] == "HyperBackup")
    }

    @Test func rejectedUpdateSaysWhichStepFailed() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.Package.Installation/install": 103, "SYNO.Core.Package.Installation/upgrade": 103]
        let test = try await TestBackend.connected(configuration: configuration)
        do {
            try await test.backend.installPackageUpdate("ContainerManager", progress: { _ in })
            Issue.record("expected an error")
        } catch BackendError.operationFailed(let message) {
            #expect(message.contains("install: v1 SYNO.Core.Package.Installation #103, v2 SYNO.Core.Package.Installation #103"))
            #expect(message.contains("upgrade(name): v1 SYNO.Core.Package.Installation #103"))
        }
    }

    @Test func packageCallsTryTheNextVersionOn103() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.Package.Installation/install@v1": 103, "SYNO.Core.Package.Installation/upgrade@v1": 103]
        let test = try await TestBackend.connected(configuration: configuration)
        try await test.backend.installPackageUpdate("ContainerManager", progress: { _ in })
        #expect(test.transport.calls("SYNO.Core.Package.Installation", "install").map { $0.params["version"] } == ["1", "2"])
        let upgrades = test.transport.calls("SYNO.Core.Package.Installation", "upgrade")
        #expect(upgrades.map { $0.params["version"] } == ["1", "2"])
        #expect(upgrades.last?.params["task_id"] == "@SYNOPKG_DOWNLOAD_ContainerManager")
        let statusVersions = Set(test.transport.calls("SYNO.Core.Package.Installation", "status").compactMap { $0.params["version"] })
        #expect(statusVersions == ["2"])
    }

    @Test func unknownDownloadMethodFallsBackToTheShortcut() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.Package.Installation/install": 103]
        let test = try await TestBackend.connected(configuration: configuration)
        try await test.backend.installPackageUpdate("ContainerManager", progress: { _ in })
        let upgrade = try #require(test.transport.calls("SYNO.Core.Package.Installation", "upgrade").first)
        #expect(upgrade.params["name"] == "ContainerManager")
    }

    @Test func writesAreNotRetriedAfterConnectionDrop() async throws {
        let test = try await TestBackend.connected()
        test.transport.configure { $0.hostErrors["nas.lan"] = .unreachable }

        await #expect(throws: BackendError.unreachable) {
            try await test.backend.perform(.stop, container: "jellyfin")
        }
        #expect(test.transport.calls("SYNO.Docker.Container", "stop").count == 1)
    }

    @Test func permissionDeniedHidesActionWithoutRelogin() async throws {
        var config = FakeDSM.Configuration()
        config.errors["SYNO.Core.Package.Control/stop"] = 105
        let test = try await TestBackend.connected(configuration: config)
        let loginsBefore = test.transport.loginCount

        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.setPackage("HyperBackup", running: false)
        }
        #expect(await test.backend.deniedActions() == [.packageControl])
        #expect(test.transport.loginCount == loginsBefore)
        #expect(test.transport.calls("SYNO.Core.Package.Control", "stop").count == 1)
    }

    @Test func packageControlSendsPackageID() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.setPackage("WebStation", running: true)
        let call = try #require(test.transport.calls("SYNO.Core.Package.Control", "start").first)
        #expect(call.params["id"] == "WebStation")
        #expect(call.method == "POST")
    }

    @Test func containerAndProjectControlUseJSONEncodedNames() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.perform(.restart, container: "jellyfin")
        try await test.backend.perform(.rebuild, project: "a1b2c3")

        let restart = try #require(test.transport.calls("SYNO.Docker.Container", "restart").first)
        #expect(restart.params["name"] == #""jellyfin""#)
        let build = try #require(test.transport.calls("SYNO.Docker.Project", "build").first)
        #expect(build.params["id"] == #""a1b2c3""#)
    }

    // MARK: DSM update and reboot

    @Test func systemUpdateWaitsForRebootAndSignsInAgain() async throws {
        let test = try await TestBackend.connected()
        let progress = ProgressRecorder()
        try await test.backend.installSystemUpdate(progress: progress.handler)

        #expect(test.transport.calls("SYNO.Core.Upgrade.Server.Download", "start").count == 1)
        #expect(test.transport.calls("SYNO.Core.Upgrade", "start").count == 1)
        #expect(test.transport.loginCount == 2)
        #expect(progress.all.last == 1)

        // Old session is gone on the NAS; the new one works without another re-login.
        _ = try await test.backend.installedPackages()
        #expect(test.transport.loginCount == 2)

        try await Task.sleep(for: .milliseconds(20))
        let states = test.events.all.compactMap { event -> ConnectionState? in
            if case .state(let state) = event { return state }
            return nil
        }
        let rebooting = try #require(states.firstIndex(of: .rebooting))
        #expect(states[rebooting...].contains(.connected))
    }

    @Test func installationPhaseDoesNotCountAsBack() async throws {
        var config = FakeDSM.Configuration()
        config.rebootUpProbes = 3
        config.rebootDownProbes = 2
        let test = try await TestBackend.connected(configuration: config)
        try await test.backend.installSystemUpdate { _ in }

        // While still installing, the old session is checked instead of signing in again.
        #expect(test.transport.loginCount == 2)
        #expect(!test.transport.calls("SYNO.Core.System", "info").isEmpty)
    }

    @Test func keepsWaitingWhileServicesStart() async throws {
        var config = FakeDSM.Configuration()
        config.loginErrorsAfterReboot = [100, 100]
        let test = try await TestBackend.connected(configuration: config)
        try await test.backend.installSystemUpdate { _ in }
        #expect(test.transport.loginCount == 2)
    }

    @Test func rejectedCredentialsAfterRebootStop() async throws {
        var config = FakeDSM.Configuration()
        config.loginErrorsAfterReboot = [400]
        let test = try await TestBackend.connected(configuration: config)
        await #expect(throws: BackendError.invalidCredentials) {
            try await test.backend.installSystemUpdate { _ in }
        }
        // Exactly one login attempt after the reboot, no loop.
        #expect(test.transport.calls("SYNO.API.Auth", "login").count == 2)
    }

    @Test func givesUpWhenTheNASDoesNotComeBack() async throws {
        var config = FakeDSM.Configuration()
        config.rebootDownProbes = .max
        var policy = DSMConnection.RebootPolicy.instant
        policy.deadline = .milliseconds(50)
        policy.sleep = { _ in try await Task.sleep(for: .milliseconds(2)) }
        let test = try await TestBackend.connected(configuration: config, rebootPolicy: policy)

        await #expect(throws: BackendError.rebootTimeout) {
            try await test.backend.installSystemUpdate { _ in }
        }
        // Normal calls fail fast while there is no session.
        await #expect(throws: BackendError.notConnected) {
            _ = try await test.backend.installedPackages()
        }
    }

    // MARK: Containers (read)

    @Test func decodesContainersWithResourcesAndExitCodes() async throws {
        let test = try await TestBackend.connected()
        let containers = try await test.backend.containers()

        #expect(containers.map(\.name) == ["jellyfin", "mosquitto", "paperless", "zigbee2mqtt"])
        let zigbee = try #require(containers.first { $0.name == "zigbee2mqtt" })
        #expect(zigbee.hasFailed)
        #expect(zigbee.exitCode == 1)
        #expect(zigbee.projectName == "smarthome")
        let paperless = try #require(containers.first { $0.name == "paperless" })
        #expect(!paperless.hasFailed)
        #expect(paperless.startedAt == nil)
        let jellyfin = try #require(containers.first { $0.name == "jellyfin" })
        let expectedMemory: Int64 = 1_237_319_680
        #expect(jellyfin.memoryBytes == expectedMemory)
        #expect(jellyfin.cpuPercent == 11.4)
        #expect(jellyfin.exitCode == nil)
        #expect(jellyfin.startedAt != nil)
    }

    @Test func projectStatusFollowsMemberContainers() async throws {
        let test = try await TestBackend.connected()
        let projects = try await test.backend.composeProjects()

        #expect(projects.map(\.name) == ["backup-tools", "smarthome"])
        #expect(projects.first { $0.name == "smarthome" }?.status == .partial)
        #expect(projects.first { $0.name == "backup-tools" }?.status == .stopped)
    }

    @Test func decodesContainerLogs() async throws {
        let test = try await TestBackend.connected()
        let lines = try await test.backend.containerLogs("zigbee2mqtt", limit: 100)
        #expect(lines.count == 2)
        #expect(lines.first?.stream == "stderr")
        #expect(lines.first?.date != nil)
        let request = try #require(test.transport.calls("SYNO.Docker.Container.Log", "get").first)
        #expect(request.params["limit"] == "100")
    }

    @Test func parsesDockerDates() {
        #expect(DSMMapping.parseDockerDate("2026-10-01T08:15:30.123456789Z") != nil)
        #expect(DSMMapping.parseDockerDate("2026-10-01T08:15:30+02:00") != nil)
        #expect(DSMMapping.parseDockerDate("0001-01-01T00:00:00Z") == nil)
        #expect(DSMMapping.parseDockerDate("garbage") == nil)
    }
}
