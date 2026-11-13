import SwiftUI

@main
struct NASCockpitApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
                .onOpenURL { url in
                    if let route = AppRoute(url: url) { app.pendingRoute = route }
                }
        }
        .onChange(of: scenePhase) { old, new in
            Task {
                if new == .background {
                    await app.sceneDidEnterBackground()
                } else if new == .active {
                    if old == .background { await app.sceneWillEnterForeground() }
                    await app.sceneDidBecomeActive()
                }
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await app.runBackgroundRefresh()
        }
    }
}
