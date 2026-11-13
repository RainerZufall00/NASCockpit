import Foundation
import Observation

/// Optional app lock (off by default). When enabled the app locks on launch and after
/// the configured time in the background, and the content is hidden in the app switcher.
@MainActor
@Observable
public final class AppLockController {
    public static let enabledKey = "appLock.enabled"
    public static let delayKey = "appLock.delay"

    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Seconds in the background before the lock engages again.
    public var lockDelay: TimeInterval {
        didSet { defaults.set(lockDelay, forKey: Self.delayKey) }
    }

    public private(set) var isLocked: Bool
    public private(set) var isUnlocking = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backgroundedAt: Date?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        let delay = defaults.object(forKey: Self.delayKey) as? TimeInterval ?? 60
        isEnabled = enabled
        lockDelay = delay
        isLocked = enabled
    }

    public func didEnterBackground() {
        backgroundedAt = .now
    }

    public func willEnterForeground() {
        guard isEnabled, let backgroundedAt else { return }
        if Date.now.timeIntervalSince(backgroundedAt) >= lockDelay {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        if await BiometricGate.confirm(reason: String(localized: "Unlock NAS Cockpit")) {
            isLocked = false
        }
    }

    /// Enabling requires a successful authentication so nobody locks the owner out.
    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            guard await BiometricGate.confirm(reason: String(localized: "Turn on the app lock")) else { return }
        }
        isEnabled = enabled
        if !enabled { isLocked = false }
    }
}
