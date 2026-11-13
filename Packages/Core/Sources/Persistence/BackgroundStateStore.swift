import Foundation
import Domain

/// What the background refresh remembers per NAS between runs. No hosts, user names or credentials.
public struct BackgroundServerState: Codable, Sendable, Hashable {
    /// Baseline for the event detection; `nil` until the first run.
    public var health: HealthState?
    /// Set after a sign-in failure in the background. The refresh skips this NAS until the user
    /// signs in successfully in the app, so DSM's Auto Block is never triggered from the background.
    public var pausedForLogin: Bool
    public var lastRun: Date?

    public init(health: HealthState? = nil, pausedForLogin: Bool = false, lastRun: Date? = nil) {
        self.health = health
        self.pausedForLogin = pausedForLogin
        self.lastRun = lastRun
    }
}

public actor BackgroundStateStore {
    private let url: URL
    private var cache: [ServerID: BackgroundServerState]?

    public init(appGroupIdentifier: String? = nil, fileName: String = "background-state.json") {
        let base = appGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        } ?? URL.applicationSupportDirectory
        url = base.appending(path: fileName)
    }

    public func all() -> [ServerID: BackgroundServerState] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([ServerID: BackgroundServerState].self, from: $0)
        } ?? [:]
        cache = loaded
        return loaded
    }

    public func state(for id: ServerID) -> BackgroundServerState {
        all()[id] ?? BackgroundServerState()
    }

    @discardableResult
    public func update<Result: Sendable>(_ id: ServerID, _ change: @Sendable (inout BackgroundServerState) -> Result) -> Result {
        var states = all()
        var state = states[id] ?? BackgroundServerState()
        let result = change(&state)
        if states[id] != state {
            states[id] = state
            write(states)
        }
        return result
    }

    public func remove(_ id: ServerID) {
        var states = all()
        guard states[id] != nil else { return }
        states[id] = nil
        write(states)
    }

    private func write(_ states: [ServerID: BackgroundServerState]) {
        cache = states
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(states).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Best effort: a lost baseline only means the next run starts fresh.
        }
    }
}
