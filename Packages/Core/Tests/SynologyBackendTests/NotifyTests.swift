import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("DSM notifications")
struct NotifyTests {
    @Test func detectsNotifications() async throws {
        let test = try await TestBackend.connected()
        #expect(await test.backend.capabilities().contains(.notifications))
    }

    @Test func loadOnlyReads() async throws {
        let test = try await TestBackend.connected()
        _ = try await test.backend.notifications()
        let call = try #require(test.transport.calls("SYNO.Core.DSMNotify", "notify").first)
        #expect(call.params["action"] == "load")
    }

    @Test func mapsCapturedResponse() async throws {
        let test = try await TestBackend.connected()
        let items = try await test.backend.notifications()
        #expect(items.count == 7)
        #expect(items.map(\.date) == items.map(\.date).sorted(by: >))

        let finished = try #require(items.first { $0.id == "1375" })
        #expect(finished.title == "Backup finished")
        #expect(finished.message == "Offsite · 39 Minuten")
        #expect(finished.level == .info)
        #expect(finished.date == Date(timeIntervalSince1970: 1_794_256_029))
        #expect(finished.details.contains(.init(label: "Destination path", value: "DiskStation_1.hbk")))
        // Host name, date and DSM's desktop hints are not shown as details.
        #expect(!finished.details.contains { $0.value == "DiskStation" || $0.value.contains("SYNO.SDS") || $0.value == "app:package_name_dev" })

        let failed = try #require(items.first { $0.id == "1365" })
        #expect(failed.title == "Backup failed")
        #expect(failed.level == .error)

        // Sent as "info" by DSM, but it reports an error-level log entry.
        let log = try #require(items.first { $0.id == "1370" })
        #expect(log.title == "Error in the system log")
        #expect(log.message == "SYSTEM: [Network][Offsite] Failed to run backup task.")
        #expect(log.level == .error)

        let container = try #require(items.first { $0.id == "1280" })
        #expect(container.title == "Container stopped unexpectedly")
        #expect(container.message == "web")
        #expect(container.level == .error)
    }

    @Test func unknownTagsStayReadable() async throws {
        let test = try await TestBackend.connected()
        let item = try #require(try await test.backend.notifications().first { $0.id == "1200" })
        #expect(item.title == "Share quota exceeded")
        #expect(item.message == "photo · 95%")
        #expect(item.level == .warning)
    }

    @Test func humanizesTags() {
        #expect(DSMMapping.humanized("IntegrityCheckFinishedTargetPass") == "Integrity check finished target pass")
        #expect(DSMMapping.humanized("docker_container_unexpected_exit") == "Docker container unexpected exit")
        #expect(DSMMapping.humanized("%DESTINATION_PATH%") == "Destination path")
    }

    @Test func plainTextMessagesAreKept() {
        #expect(DSMMapping.notifyVariables(["Just text"]).isEmpty)
    }
}
