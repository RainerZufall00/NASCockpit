import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var showAddServer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .padding(.top, 32)
                        Text("NAS Cockpit")
                            .font(.largeTitle.weight(.bold))
                        Text("All your NAS and all their updates in one place. Free, no tracking. Your servers sync only through your own iCloud.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        Button {
                            showAddServer = true
                        } label: {
                            Label("Add Server", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            Task { await app.startDemo() }
                        } label: {
                            Label("Try the Demo", systemImage: "play.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Recommendations").font(.headline)
                        Recommendation(
                            symbol: "network.badge.shield.half.filled",
                            title: "Use a VPN on the go",
                            text: "Don’t expose your NAS to the internet. Connect through WireGuard or Tailscale instead. QuickConnect is not supported."
                        )
                        Recommendation(
                            symbol: "person.badge.key",
                            title: "Use a dedicated admin account",
                            text: "Create an account in the “administrators” group with two-factor authentication, and enable Auto Block in DSM."
                        )
                        Recommendation(
                            symbol: "faceid",
                            title: "Turn on the app lock",
                            text: "Sessions stay open while the app runs. The app lock protects them on an unlocked device."
                        )
                    }
                    .padding()
                    .background(.background.secondary, in: .rect(cornerRadius: 20))

                    Text("NAS Cockpit is an independent app and is not affiliated with or endorsed by Synology Inc. Compatible with Synology DSM 7.2 and later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView(manager: app.live)
            }
        }
    }
}

private struct Recommendation: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
