import Foundation
import Synchronization
import Testing
@testable import Domain

final class Timeline: Sendable {
    private let entries = Mutex<[String]>([])
    var all: [String] { entries.withLock { $0 } }
    func log(_ entry: String) { entries.withLock { $0.append(entry) } }
}

@MainActor
@Suite("Operation center")
struct OperationCenterTests {
    let serverA = UUID()
    let serverB = UUID()

    @Test func runsSequentiallyPerNASAndInParallelAcrossNAS() async {
        let center = OperationCenter()
        let timeline = Timeline()

        func work(_ name: String, _ duration: Duration) -> OperationCenter.Work {
            { _ in
                timeline.log("start \(name)")
                try await Task.sleep(for: duration)
                timeline.log("end \(name)")
            }
        }

        center.enqueue(serverID: serverA, serverName: "A", kind: .packageUpdate(packageID: "a1"), title: "a1", work: work("a1", .milliseconds(60)))
        center.enqueue(serverID: serverA, serverName: "A", kind: .packageUpdate(packageID: "a2"), title: "a2", work: work("a2", .milliseconds(10)))
        center.enqueue(serverID: serverB, serverName: "B", kind: .packageUpdate(packageID: "b1"), title: "b1", work: work("b1", .milliseconds(10)))

        await center.waitUntilIdle(serverA)
        await center.waitUntilIdle(serverB)

        let events = timeline.all
        let index = { (entry: String) in events.firstIndex(of: entry) ?? -1 }
        // Same NAS: a2 starts only after a1 ended.
        #expect(index("start a2") > index("end a1"))
        // Other NAS: b1 does not wait for a1.
        #expect(index("start b1") < index("end a1"))
        #expect(center.operations.allSatisfy { $0.status == .succeeded })
        #expect(center.completedCount == 3)
    }

    @Test func failureDoesNotStopTheQueue() async {
        let center = OperationCenter()
        center.enqueue(serverID: serverA, serverName: "A", kind: .systemUpdate, title: "fails") { _ in
            throw BackendError.actionNotPermitted
        }
        center.enqueue(serverID: serverA, serverName: "A", kind: .packageStart(packageID: "x"), title: "works") { _ in }
        await center.waitUntilIdle(serverA)

        #expect(center.latest(.systemUpdate, on: serverA)?.status == .failed(.actionNotPermitted))
        #expect(center.visible(.systemUpdate, on: serverA) != nil)
        #expect(center.latest(.packageStart(packageID: "x"), on: serverA)?.status == .succeeded)
        #expect(center.visible(.packageStart(packageID: "x"), on: serverA) == nil)
        #expect(!center.hasActiveOperations(on: serverA))
    }

    @Test func reportsProgressAndBusyState() async throws {
        let center = OperationCenter()
        let gate = AsyncStream.makeStream(of: Void.self)
        let kind = OperationCenter.Kind.packageUpdate(packageID: "p")

        center.enqueue(serverID: serverA, serverName: "A", kind: kind, title: "p") { progress in
            progress(0.5)
            for await _ in gate.stream { break }
        }
        #expect(center.isBusy(kind, on: serverA))

        // Progress arrives asynchronously on the main actor.
        for _ in 0..<50 {
            if case .running(let value?) = center.latest(kind, on: serverA)?.status, value == 0.5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(center.latest(kind, on: serverA)?.status == .running(progress: 0.5))

        gate.continuation.yield()
        gate.continuation.finish()
        await center.waitUntilIdle(serverA)
        #expect(!center.isBusy(kind, on: serverA))
        center.clearFinished()
        #expect(center.operations.isEmpty)
    }
}
