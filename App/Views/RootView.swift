import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            let manager = app.activeManager
            if manager.isDemo || !manager.profiles.isEmpty {
                MainSplitView(manager: manager)
                    .id(manager.isDemo)
            } else {
                OnboardingView()
            }
        }
        .overlay {
            // Locked, or hidden in the app switcher while the lock is enabled.
            if app.lock.isLocked || (app.lock.isEnabled && scenePhase != .active) {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: app.lock.isLocked)
    }
}

struct LockScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("NAS Cockpit is locked").font(.title3.weight(.semibold))
                if app.lock.isLocked {
                    Button {
                        Task { await app.lock.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .task {
            if app.lock.isLocked { await app.lock.unlock() }
        }
    }
}
