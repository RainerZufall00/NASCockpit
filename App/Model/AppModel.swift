import Foundation
import Observation
import CoreData
import SwiftData
import UIKit
import UserNotifications
import WidgetKit
import Domain
import Persistence
import SecurityKit

enum AppConstants {
    /// Shared with the widget extension. Without the entitlement the cache falls back to Application Support.
    static let appGroup = SharedStorage.appGroup
    /// Registered in Info.plist. Used by the widgets: `nascockpit://server/<uuid>`, `nascockpit://updates`.
    static let urlScheme = "nascockpit"
}

/// Where a tapped notification or widget wants to go.
enum AppRoute: Hashable {
    case server(ServerID)
    case updates

    init?(url: URL) {
        guard url.scheme == AppConstants.urlScheme else { return nil }
        switch url.host() {
        case "updates": self = .updates
        case "server":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .server(id)
        default: return nil
        }
    }
}

/// Opens the NAS a notification is about. Notifications that arrive while the app is open are shown as banners.
///
/// Uses the completion-handler variants on purpose: with the async variants Swift calls the system's
/// completion handler off the main thread, and UIKit aborts the app when the user taps a notification.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (ServerID) -> Void = { _ in }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["serverID"] as? String
        if let id = raw.flatMap(UUID.init(uuidString:)) { onOpen(id) }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let live: ConnectionManager
    private(set) var demo: ConnectionManager?
    let lock = AppLockController()
    /// Set by a tapped notification or widget; the main view navigates and clears it.
    var pendingRoute: AppRoute?
    @ObservationIgnored private let notificationRouter = NotificationRouter()

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        do {
            container = try ProfileRepository.makeContainer(cloudSync: ProfileSync.isEnabled)
        } catch {
            // A broken store must not brick the app; fall back to memory and let the user re-add.
            container = try! ProfileRepository.makeContainer(inMemory: true)
        }
        live = .live(repository: ProfileRepository(container: container))
        observeProfileChanges()
        // Must be set before launch finishes so a tap that starts the app is delivered.
        notificationRouter.onOpen = { [weak self] id in self?.pendingRoute = .server(id) }
        UNUserNotificationCenter.current().delegate = notificationRouter
    }

    @ObservationIgnored private var profileChangeTask: Task<Void, Never>?

    /// iCloud imports profiles in the background and posts this for every store change (also our own saves,
    /// which `reloadProfiles` recognises as no change). Coalesced, because one import posts several.
    private func observeProfileChanges() {
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.profileChangeTask?.cancel()
                self.profileChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, self.didStart else { return }
                    await self.live.reloadProfiles()
                }
            }
        }
    }

    var activeManager: ConnectionManager { demo ?? live }
    var isDemoActive: Bool { demo != nil }

    func start() async {
        guard !didStart else { return }
        didStart = true
        #if DEBUG
        // Lets the simulator test notification taps without adding a server first.
        if ProcessInfo.processInfo.arguments.contains("-requestNotifications") {
            _ = await BackgroundRefresh.requestNotificationPermission()
        }
        // Shows the sign-in prompts with demo data: `-demoPrompt password` or `-demoPrompt otp`.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoPrompt"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            await startDemo()
            if let id = demo?.profiles.first?.id {
                if ProcessInfo.processInfo.arguments[index + 1] == "otp" { demo?.requestOTP(for: id) } else { demo?.requestPassword(for: id) }
            }
            return
        }
        #endif
        await live.load()
        // Merges a NAS that was added on two devices before sync was on.
        await live.reloadProfiles()
        await connectWhenReady(live)
    }

    @ObservationIgnored private var isConnectingAll = false

    /// Face ID only works while the app is on screen: a launch for background refresh must not try to unlock
    /// the saved passwords (it would fail and leave every NAS on "Sign-in required"). With the app lock on,
    /// wait until it is unlocked so the two Face ID prompts do not cancel each other.
    private func connectWhenReady(_ manager: ConnectionManager) async {
        guard UIApplication.shared.applicationState != .background, !isConnectingAll else { return }
        isConnectingAll = true
        defer { isConnectingAll = false }
        while lock.isLocked {
            try? await Task.sleep(for: .milliseconds(300))
            if UIApplication.shared.applicationState == .background { return }
        }
        await manager.connectAll()
    }

    func startDemo() async {
        let manager = ConnectionManager.demo()
        demo = manager
        await manager.load()
        await manager.connectAll()
    }

    func exitDemo() async {
        await demo?.disconnectAll()
        demo = nil
    }

    func sceneDidEnterBackground() async {
        lock.didEnterBackground()
        await live.keychain?.invalidateAuthentication()
        keepRunningWhileOperationsActive()
        BackgroundRefresh.schedule(enabled: live.profiles.contains(where: \.backgroundRefresh))
        // The widgets show what the app saw last.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Entry point of the `BGAppRefreshTask`. Read-only; signs in with the background copy and out again.
    func runBackgroundRefresh() async {
        if live.profiles.isEmpty { await live.load() }
        let profiles = live.profiles.filter(\.backgroundRefresh)
        // Ask for the next run first: if iOS ends this one early, the chain continues.
        BackgroundRefresh.schedule(enabled: !profiles.isEmpty)
        guard UIApplication.shared.applicationState != .active,
              let keychain = live.keychain, let statusCache = live.statusCache, let state = live.backgroundState else { return }
        await BackgroundRefresher(keychain: keychain, statusCache: statusCache, state: state).run(profiles)
    }

    /// Asks iOS for a little extra time so a running update can finish its current step.
    /// Polling continues when the app returns to the foreground.
    private func keepRunningWhileOperationsActive() {
        guard !activeManager.operations.active.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NAS operations") { [weak self] in
            self?.endBackgroundTask()
        }
        Task { [weak self] in
            while let self, self.backgroundTask != .invalid, !self.activeManager.operations.active.isEmpty {
                try? await Task.sleep(for: .seconds(1))
            }
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func sceneWillEnterForeground() async {
        lock.willEnterForeground()
    }

    /// Every time the app comes on screen, also after a launch in the background.
    func sceneDidBecomeActive() async {
        await connectWhenReady(activeManager)
    }
}
