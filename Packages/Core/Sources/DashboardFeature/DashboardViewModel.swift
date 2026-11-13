import Foundation
import Observation
import Domain

@MainActor
@Observable
public final class DashboardViewModel {
    public struct Sample: Identifiable, Hashable {
        public var id: Date { date }
        public let date: Date
        public let cpu: Double
        public let memory: Double
        public let rx: Double
        public let tx: Double
    }

    public let serverName: String
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var history: [Sample] = []
    public private(set) var error: BackendError?

    /// Base polling interval while the dashboard is visible (doubled in Low Power Mode).
    public var baseInterval: Duration = .seconds(4)
    /// Keep the last minutes in memory only.
    private let historyWindow: TimeInterval = 300

    @ObservationIgnored private let backend: any ServerBackend

    public init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    public func refresh() async {
        do {
            let snapshot = try await backend.systemSnapshot()
            apply(snapshot)
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }

    /// Polls until the task is cancelled (view disappears or app goes to the background).
    public func runPolling() async {
        while !Task.isCancelled {
            await refresh()
            let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? baseInterval * 2 : baseInterval
            try? await Task.sleep(for: interval)
        }
    }

    func apply(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        error = nil
        history.append(Sample(
            date: snapshot.capturedAt,
            cpu: snapshot.cpuLoad ?? 0,
            memory: snapshot.memoryUsage ?? 0,
            rx: snapshot.network?.rxBytesPerSecond ?? 0,
            tx: snapshot.network?.txBytesPerSecond ?? 0
        ))
        let cutoff = snapshot.capturedAt.addingTimeInterval(-historyWindow)
        history.removeAll { $0.date < cutoff }
    }
}
