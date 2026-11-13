import Foundation
import Observation

/// Runs write operations (updates, start/stop, DSM update) independently of the visible screen.
///
/// Operations on the same NAS run one after another; different NAS run in parallel.
@MainActor
@Observable
public final class OperationCenter {
    public enum Kind: Hashable, Sendable {
        case packageUpdate(packageID: String)
        case packageStart(packageID: String)
        case packageStop(packageID: String)
        case systemUpdate
        case container(ContainerAction, name: String)
        case project(ProjectAction, id: String)
        case power(PowerAction)
        case fileTransfer(TransferMode, path: String)
        case fileDelete(path: String)
        case guest(GuestAction, id: String)
        case guestSnapshot(GuestSnapshotAction, guestID: String, name: String)
        case refreshCatalog
        case backup(BackupControl, taskID: String)
        case snapshot(share: String)
        case replicationSync(planID: String)
    }

    public enum Status: Hashable, Sendable {
        case queued
        case running(progress: Double?)
        case succeeded
        case failed(BackendError)

        public var isFinished: Bool {
            switch self {
            case .succeeded, .failed: true
            case .queued, .running: false
            }
        }
    }

    public struct Operation: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let serverID: ServerID
        public let serverName: String
        public let kind: Kind
        public let title: String
        public internal(set) var status: Status
        public let createdAt: Date
        public internal(set) var finishedAt: Date?
    }

    public typealias Work = @Sendable (_ progress: @escaping ProgressHandler) async throws -> Void

    public private(set) var operations: [Operation] = []
    /// Increments whenever an operation finishes. Views use it with `onChange` to reload.
    public private(set) var completedCount = 0

    /// Face ID / passcode confirmation, injected by the app (features don't depend on SecurityKit).
    @ObservationIgnored public var authorize: @MainActor (_ reason: String) async -> Bool = { _ in true }
    /// Called after every operation, e.g. to refresh update counts.
    @ObservationIgnored public var onFinish: @MainActor (Operation) -> Void = { _ in }

    @ObservationIgnored private var tails: [ServerID: Task<Void, Never>] = [:]

    public init() {}

    public var active: [Operation] { operations.filter { !$0.status.isFinished } }

    /// Latest operation of this kind on this NAS.
    public func latest(_ kind: Kind, on serverID: ServerID) -> Operation? {
        operations.last { $0.serverID == serverID && $0.kind == kind }
    }

    public func isBusy(_ kind: Kind, on serverID: ServerID) -> Bool {
        latest(kind, on: serverID).map { !$0.status.isFinished } ?? false
    }

    /// Running or queued operation of this kind, or one that failed (shown until cleared or retried).
    public func visible(_ kind: Kind, on serverID: ServerID) -> Operation? {
        guard let operation = latest(kind, on: serverID) else { return nil }
        if case .succeeded = operation.status { return nil }
        return operation
    }

    public func hasActiveOperations(on serverID: ServerID) -> Bool {
        operations.contains { $0.serverID == serverID && !$0.status.isFinished }
    }

    @discardableResult
    public func enqueue(serverID: ServerID, serverName: String, kind: Kind, title: String, work: @escaping Work) -> UUID {
        let operation = Operation(id: UUID(), serverID: serverID, serverName: serverName, kind: kind, title: title, status: .queued, createdAt: .now)
        operations.append(operation)
        let id = operation.id
        let previous = tails[serverID]
        tails[serverID] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.update(id) { $0.status = .running(progress: nil) }
            let progress: ProgressHandler = { [weak self] value in
                Task { @MainActor in self?.reportProgress(value, for: id) }
            }
            do {
                try await work(progress)
                self.update(id) {
                    $0.status = .succeeded
                    $0.finishedAt = .now
                }
            } catch {
                self.update(id) {
                    $0.status = .failed(BackendError(error))
                    $0.finishedAt = .now
                }
            }
            self.completedCount += 1
            if let finished = self.operations.first(where: { $0.id == id }) {
                self.onFinish(finished)
            }
        }
        return id
    }

    /// Waits until all queued operations of a NAS are done (used by tests and the bulk flow).
    public func waitUntilIdle(_ serverID: ServerID) async {
        await tails[serverID]?.value
    }

    public func clearFinished() {
        operations.removeAll { $0.status.isFinished }
    }

    private func reportProgress(_ value: Double?, for id: UUID) {
        update(id) { operation in
            guard case .running = operation.status else { return }
            operation.status = .running(progress: value.map { min(1, max(0, $0)) })
        }
    }

    private func update(_ id: UUID, _ change: (inout Operation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        change(&operations[index])
    }
}
