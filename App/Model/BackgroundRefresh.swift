import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import WidgetKit
import Domain
import Persistence
import SecurityKit
import SynologyBackend

enum BackgroundRefresh {
    /// Also listed in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifier = "com.nascockpit.app.refresh"

    /// iOS decides when the task really runs; this is only the earliest moment.
    static func schedule(enabled: Bool) {
        guard enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Whether iOS currently lets this app refresh in the background (Settings → General → Background App Refresh).
    @MainActor
    static var backgroundRefreshStatus: UIBackgroundRefreshStatus {
        UIApplication.shared.backgroundRefreshStatus
    }

    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Asks once; later calls return the stored answer without a prompt.
    static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func notificationsDenied() async -> Bool {
        await notificationStatus() == .denied
    }

    static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Delivered a few seconds later, so the user can lock the device and see that notifications arrive.
    static func sendTestNotification(serverName: String) async -> Bool {
        guard await requestNotificationPermission() else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(serverName): Test notification")
        content.body = String(localized: "Notifications from NAS Cockpit reach this device.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}

/// App-wide notification options (Settings). Plain `UserDefaults`, read by the background run.
enum NotificationPreferences {
    static let volumeThresholdKey = "notifications.volumeThreshold"
    static let quietHoursEnabledKey = "notifications.quietHours.enabled"
    static let quietHoursStartKey = "notifications.quietHours.start"
    static let quietHoursEndKey = "notifications.quietHours.end"

    static let volumeThresholds = [0.8, 0.85, 0.9, 0.95]
    static let defaultQuietStart = 22 * 60
    static let defaultQuietEnd = 7 * 60

    static var volumeThreshold: Double {
        let value = UserDefaults.standard.double(forKey: volumeThresholdKey)
        return volumeThresholds.contains(value) ? value : HealthEventDetector.defaultVolumeFullThreshold
    }

    /// During quiet hours notifications still arrive, but without sound and without lighting up the screen.
    static func isQuiet(at date: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: quietHoursEnabledKey) else { return false }
        let start = defaults.object(forKey: quietHoursStartKey) as? Int ?? defaultQuietStart
        let end = defaults.object(forKey: quietHoursEndKey) as? Int ?? defaultQuietEnd
        return isQuiet(minute: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date), start: start, end: end)
    }

    /// Minutes since midnight. A range that ends before it starts runs over midnight.
    static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        return start < end ? (start..<end).contains(minute) : (minute >= start || minute < end)
    }
}

/// One background run: for every NAS with opt-in, sign in with the background copy, read status,
/// updates, containers and backup tasks, write the widget cache, report new events, sign out. Never writes to a NAS.
struct BackgroundRefresher: Sendable {
    let keychain: KeychainCredentialStore
    let statusCache: StatusCache
    let state: BackgroundStateStore

    func run(_ profiles: [ServerProfile]) async {
        let deviceName = ConnectionManager.deviceName
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles where profile.backgroundRefresh {
                group.addTask { await refresh(profile, deviceName: deviceName) }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refresh(_ profile: ServerProfile, deviceName: String) async {
        let id = profile.id
        // Paused after a sign-in failure: no further attempt until the user signs in in the app.
        guard await !state.state(for: id).pausedForLogin else { return }
        guard (try? await keychain.hasBackgroundCopy(for: id)) == true else { return }

        let backend = BackendFactory.make(for: profile, credentials: BackgroundCredentialProvider(store: keychain), deviceName: deviceName, interactive: false)
        do {
            try await backend.connect(otp: nil)
        } catch {
            if Self.needsUser(BackendError(error)) {
                await state.update(id) { $0.pausedForLogin = true }
                await writeStatus(profile) { $0.needsLogin = true }
            }
            // Not reachable (no VPN, away from home) is normal and never reported.
            return
        }

        // iOS gives an app-refresh task roughly 30 seconds. Status and updates come first; the
        // optional reads are skipped when the NAS answered slowly, so the run still ends in time.
        let clock = ContinuousClock()
        let start = clock.now
        let budget: Duration = .seconds(15)
        let snapshot = try? await backend.systemSnapshot()
        let updates = try? await backend.updates()
        let capabilities = await backend.capabilities()
        let containers: [ContainerItem]? = if capabilities.contains(.containers), clock.now - start < budget {
            try? await backend.containers()
        } else {
            nil
        }
        let backups: [BackupTask]? = if capabilities.contains(.backup), profile.notifyBackupFailures, clock.now - start < budget {
            try? await backend.backupTasks()
        } else {
            nil
        }
        await backend.disconnect()

        await writeStatus(profile) { status in
            status.needsLogin = false
            if let snapshot {
                status.snapshot = snapshot
                status.lastReached = .now
            }
            if let updates { status.pendingUpdates = updates.count }
        }

        let threshold = NotificationPreferences.volumeThreshold
        let events = await state.update(id) { entry in
            let result = HealthEventDetector.evaluate(
                previous: entry.health, snapshot: snapshot, updates: updates, containers: containers,
                backups: backups, volumeFullThreshold: threshold
            )
            entry.health = result.state
            entry.lastRun = .now
            return result.events
        }
        await Self.notify(events, profile: profile)
    }

    /// Posts one notification per event the profile allows. Returns how many were posted.
    @discardableResult
    static func notify(_ events: [HealthEvent], profile: ServerProfile) async -> Int {
        let quiet = NotificationPreferences.isQuiet()
        var count = 0
        for event in events where profile.allowsNotification(for: event) {
            await notify(event, profile: profile, quiet: quiet)
            count += 1
        }
        return count
    }

    /// Sign-in and certificate problems need the user; retrying in the background could trigger Auto Block.
    private static func needsUser(_ error: BackendError) -> Bool {
        switch error {
        case .certificateUntrusted, .fingerprintChanged: true
        default: error.isAuthenticationFailure
        }
    }

    private func writeStatus(_ profile: ServerProfile, _ change: (inout CachedServerStatus) -> Void) async {
        var status = await statusCache.load()[profile.id]
            ?? CachedServerStatus(serverID: profile.id, name: profile.name, snapshot: nil, pendingUpdates: nil, lastReached: nil)
        status.name = profile.name
        status.iconName = profile.iconName
        status.colorName = profile.colorName
        status.updatedAt = .now
        change(&status)
        await statusCache.update(status)
    }

    // MARK: Notifications

    private static func notify(_ event: HealthEvent, profile: ServerProfile, quiet: Bool) async {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = profile.id.uuidString
        content.userInfo = ["serverID": profile.id.uuidString]
        if quiet {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let name = profile.name
        switch event {
        case .storageProblems(let problems):
            content.title = String(localized: "\(name): Storage problem")
            content.body = problems.map(describe).joined(separator: "\n")
        case .packageUpdates(let names):
            content.title = String(localized: "\(name): \(names.count) new package updates")
            content.body = names.formatted(.list(type: .and))
        case .systemUpdate(let version):
            content.title = String(localized: "\(name): DSM update available")
            content.body = version
        case .containerFailed(let container, let exitCode):
            content.title = String(localized: "\(name): Container stopped with an error")
            content.body = String(localized: "\(container) exited with code \(String(exitCode)).")
        case .backupFailed(let task, let partial):
            content.title = partial
                ? String(localized: "\(name): Backup finished with skipped files")
                : String(localized: "\(name): Backup failed")
            content.body = task
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func describe(_ problem: HealthEvent.StorageProblem) -> String {
        switch problem {
        case .volume(let name, let status):
            switch status {
            case .crashed: String(localized: "\(name) has crashed.")
            case .degraded: String(localized: "\(name) is degraded.")
            default: String(localized: "\(name) reports a warning.")
            }
        case .volumeFull(let name, let usage):
            String(localized: "\(name) is \(usage.formatted(.percent.precision(.fractionLength(0)))) full.")
        case .disk(let name, let status):
            status == .crashed
                ? String(localized: "\(name) has failed.")
                : String(localized: "\(name) reports a warning.")
        }
    }
}
