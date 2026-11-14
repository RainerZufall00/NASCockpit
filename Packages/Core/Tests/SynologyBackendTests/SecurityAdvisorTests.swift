import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("Security Advisor")
struct SecurityAdvisorTests {
    @Test func detectsSecurityAdvisor() async throws {
        let test = try await TestBackend.connected()
        #expect(await test.backend.capabilities().contains(.securityAdvisor))
    }

    @Test func mapsLastScan() async throws {
        let test = try await TestBackend.connected()
        let report = try await test.backend.securityReport()
        #expect(report.overall == .warning)
        #expect(!report.isScanning)
        #expect(report.progress == nil)
        #expect(report.lastScan == Date(timeIntervalSince1970: 1_794_103_201))
        // DSM's order, not the order of the JSON keys.
        #expect(report.groups.map(\.id) == ["malware", "systemCheck", "securitySetting", "userInfo", "network", "update"])
        #expect(report.checkCount == 23)
        #expect(report.failedCount == 4)
        // "info" is a note, not an issue.
        #expect(report.issueCount == 3)

        let update = try #require(report.groups.first { $0.id == "update" })
        #expect(update.failures == [.outOfDate: 2])
        #expect(update.severity == .outOfDate)
        #expect(update.passedCount == 2)
    }

    @Test func listsFailedRulesOnly() async throws {
        let test = try await TestBackend.connected()
        let report = try await test.backend.securityReport()
        // Passed and skipped rules are left out; most severe first.
        #expect(report.findings.map(\.id) == ["securityscan:rule_ssh_default_port", "pkg_outdated"])
        let ssh = try #require(report.findings.first)
        #expect(ssh.title == "Ssh default port")
        #expect(ssh.group == "network")
        #expect(ssh.severity == .warning)
        #expect(report.findings.last?.title == "Package updates available")
        #expect(test.transport.calls("SYNO.Core.SecurityScan.Status", "rule_get").first?.params["items"] == "ALL")
    }

    @Test func mapsRunningScan() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.securityScanRunning = true
        let test = try await TestBackend.connected(configuration: configuration)
        let report = try await test.backend.securityReport()
        #expect(report.isScanning)
        #expect(report.progress == 0.45)
        let network = try #require(report.groups.first { $0.id == "network" })
        #expect(network.isRunning)
        #expect(network.progress == 0.4)
        let malware = try #require(report.groups.first { $0.id == "malware" })
        #expect(!malware.isRunning)
    }

    @Test func rulesAreOptional() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.SecurityScan.Status/rule_get": 103]
        let test = try await TestBackend.connected(configuration: configuration)
        let report = try await test.backend.securityReport()
        #expect(report.findings.isEmpty)
        #expect(report.failedCount == 4)
    }

    @Test func startScanIsAWrite() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.startSecurityScan()
        let call = try #require(test.transport.calls("SYNO.Core.SecurityScan.Operation", "start").first)
        #expect(call.method == "POST")
        #expect(test.transport.calls("SYNO.Core.SecurityScan.Operation", "specific_start").isEmpty)
    }

    @Test func startFallsBackToSpecificStart() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.SecurityScan.Operation/start": 103]
        let test = try await TestBackend.connected(configuration: configuration)
        try await test.backend.startSecurityScan()
        let call = try #require(test.transport.calls("SYNO.Core.SecurityScan.Operation", "specific_start").first)
        #expect(call.params["items"] == "ALL")
    }

    @Test func permissionDeniedHidesScanAction() async throws {
        var configuration = FakeDSM.Configuration()
        configuration.errors = ["SYNO.Core.SecurityScan.Operation/start": 105]
        let test = try await TestBackend.connected(configuration: configuration)
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.startSecurityScan()
        }
        #expect(await test.backend.deniedActions().contains(.securityScan))
        #expect(test.transport.calls("SYNO.Core.SecurityScan.Operation", "specific_start").isEmpty)
    }

    @Test func readableRuleTitles() {
        #expect(DSMMapping.securityRuleTitle("securityscan:rule_admin_disabled") == "Admin disabled")
        #expect(DSMMapping.securityRuleTitle("checkAutoBlockEnabled") == "Auto block enabled")
        #expect(DSMMapping.securityRuleTitle("telnet") == "Telnet")
    }
}
