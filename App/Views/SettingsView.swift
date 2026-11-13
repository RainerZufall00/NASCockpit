import SwiftUI
import UserNotifications
import Domain
import Persistence
import SecurityKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { app.lock.isEnabled },
                        set: { newValue in Task { await app.lock.setEnabled(newValue) } }
                    )) {
                        Label("App Lock", systemImage: "faceid")
                    }
                    if app.lock.isEnabled {
                        Picker("Lock After", selection: Binding(get: { app.lock.lockDelay }, set: { app.lock.lockDelay = $0 })) {
                            Text("Immediately").tag(TimeInterval(0))
                            Text("1 minute").tag(TimeInterval(60))
                            Text("5 minutes").tag(TimeInterval(300))
                            Text("15 minutes").tag(TimeInterval(900))
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Sessions stay open while the app runs. With the app lock, \(BiometricGate.biometryName) protects them and the content is hidden in the app switcher. Destructive actions always require \(BiometricGate.biometryName).")
                }

                if !app.isDemoActive, !app.live.profiles.isEmpty {
                    Section {
                        ForEach(app.live.profiles) { profile in
                            NavigationLink {
                                BackgroundSettingsView(serverID: profile.id)
                            } label: {
                                LabeledContent {
                                    Text(profile.backgroundRefresh ? "On" : "Off")
                                } label: {
                                    Label(profile.name, systemImage: profile.iconName)
                                }
                            }
                        }
                    } header: {
                        Text("Background Refresh & Notifications")
                    } footer: {
                        Text("Per NAS: status for the widgets and notifications about storage problems, new updates, failed containers and failed backups.")
                    }

                    if app.live.profiles.contains(where: \.backgroundRefresh) {
                        NotificationOptionsSection()
                    }
                }

                if !app.isDemoActive {
                    ICloudSyncSection()
                }

                TerminalAppSection()

                if app.isDemoActive {
                    Section {
                        Button("Exit Demo") {
                            Task {
                                await app.exitDemo()
                                dismiss()
                            }
                        }
                    }
                }

                Section("Recommendations") {
                    Label("Access your NAS from outside only through a VPN (WireGuard, Tailscale).", systemImage: "network.badge.shield.half.filled")
                    Label("Use a dedicated admin account with two-factor authentication.", systemImage: "person.badge.key")
                    Label("Enable Auto Block in DSM.", systemImage: "hand.raised")
                }
                .font(.subheadline)

                Section("Privacy") {
                    Label("No analytics, no tracking. Data only goes to your NAS and, with iCloud Sync, end-to-end encrypted to your own iCloud.", systemImage: "hand.raised.fill")
                        .font(.subheadline)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                } footer: {
                    Text("NAS Cockpit is an independent app and is not affiliated with or endorsed by Synology Inc.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// iCloud sync of the server profiles. The store opens once per launch, so a change applies after a restart.
struct ICloudSyncSection: View {
    @State private var isEnabled = ProfileSync.isEnabled
    private let enabledAtLaunch = ProfileSync.isEnabled

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label("iCloud Sync", systemImage: "icloud")
            }
            .onChange(of: isEnabled) { _, newValue in ProfileSync.isEnabled = newValue }
        } header: {
            Text("Devices")
        } footer: {
            if isEnabled != enabledAtLaunch {
                Text("Takes effect the next time NAS Cockpit starts.")
            } else {
                Text("Your servers appear on all devices with your Apple Account: names, addresses, user names and the trusted certificate, end-to-end encrypted. Passwords, API tokens and the background refresh stay on this device; on a new device you sign in once.")
            }
        }
    }
}

/// Background refresh opt-in and the notification matrix of one NAS.
struct BackgroundSettingsView: View {
    let serverID: ServerID

    @Environment(AppModel.self) private var app
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notificationsDenied = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var paused = false
    @State private var lastRun: Date?
    @State private var testSent = false
    @State private var checkResult: String?
    @State private var isChecking = false

    private var manager: ConnectionManager { app.live }

    var body: some View {
        if let profile = manager.profile(serverID) {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { profile.backgroundRefresh },
                        set: { setEnabled($0) }
                    )) {
                        Label("Background Refresh", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isWorking || !profile.canSignInUnattended)
                    if profile.backgroundRefresh {
                        if paused {
                            Label("Paused: sign in to this NAS in the app to continue.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                        }
                        LabeledContent("Last Run") {
                            if let lastRun {
                                Text(lastRun, format: .relative(presentation: .named))
                            } else {
                                Text("Not yet")
                            }
                        }
                    }
                } footer: {
                    if profile.authMethod.isOpenID, !profile.hasAPIToken {
                        Text("This server signs in through your identity provider in the browser, which is not possible in the background. Remove and add it again with an API token to use background refresh.")
                    } else if profile.canSignInUnattended {
                        Text("iOS decides when the refresh runs, typically a few times a day and never on a fixed schedule. The app signs in, reads the status and signs out; it never changes anything on the NAS in the background.\n\nFor this, a copy of the password is kept in the Keychain of this device that can be read while the device is locked. Turning this off deletes the copy.")
                    } else {
                        Text("Background refresh needs a saved password. This NAS is set to ask for the password every time.")
                    }
                }

                if profile.backgroundRefresh {
                    diagnostics(profile)

                    Section {
                        matrixToggle("Storage Problems", "externaldrive.badge.exclamationmark", \.storageProblems, profile)
                        matrixToggle("New Package Updates", "shippingbox", \.packageUpdates, profile)
                        if profile.backend == .synology {
                            matrixToggle("DSM Updates", "arrow.down.circle", \.systemUpdates, profile)
                        }
                        if profile.backend == .synology {
                            matrixToggle("Failed Containers", "cube.box", \.containerFailures, profile)
                        }
                        Toggle(isOn: Binding(
                            get: { profile.notifyBackupFailures },
                            set: { manager.setNotifyBackupFailures(serverID, $0) }
                        )) {
                            Label("Failed Backups", systemImage: "clock.arrow.circlepath")
                        }
                    } header: {
                        Text("Notifications")
                    } footer: {
                        if notificationsDenied {
                            Text("Notifications are turned off for NAS Cockpit in the iOS Settings.")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Each problem is reported once. An unreachable NAS is never reported, because away from home without VPN every NAS is unreachable. For outages, keep using DSM's own notifications.")
                        }
                    }
                }
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadStatus() }
            .alert("Background Refresh", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Everything that has to be right for a notification to arrive, with a test for each half.
    @ViewBuilder
    private func diagnostics(_ profile: ServerProfile) -> some View {
        let refreshStatus = BackgroundRefresh.backgroundRefreshStatus
        let connected = manager.runtime[profile.id]?.state.isConnected == true
        Section {
            LabeledContent {
                Text(notificationStatusTitle)
                    .foregroundStyle(notificationStatus == .authorized ? Color.secondary : Color.orange)
            } label: {
                Label("Notifications", systemImage: "bell")
            }
            LabeledContent {
                Text(refreshStatus == .available ? "On" : "Off")
                    .foregroundStyle(refreshStatus == .available ? Color.secondary : Color.orange)
            } label: {
                Label("Background App Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            if BackgroundRefresh.isLowPowerMode {
                Label("Low Power Mode is on: iOS pauses background refresh.", systemImage: "battery.25percent")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
            if notificationStatus != .authorized || refreshStatus != .available {
                Button("Open iOS Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button {
                Task {
                    testSent = await BackgroundRefresh.sendTestNotification(serverName: profile.name)
                    await loadStatus()
                }
            } label: {
                Label(testSent ? "Test Notification Sent" : "Send Test Notification", systemImage: testSent ? "checkmark.circle" : "paperplane")
            }
            Button {
                isChecking = true
                checkResult = nil
                Task {
                    defer { isChecking = false }
                    if let count = await manager.checkHealthNow(profile.id) {
                        checkResult = count == 0
                            ? String(localized: "Checked: nothing new to report.")
                            : String(localized: "Checked: \(count) notifications sent.")
                    } else {
                        checkResult = String(localized: "Not connected to this NAS.")
                    }
                    await loadStatus()
                }
            } label: {
                HStack {
                    Label("Check Now", systemImage: "stethoscope")
                    if isChecking { Spacer(); ProgressView() }
                }
            }
            .disabled(isChecking || !connected)
            if let checkResult {
                Text(checkResult).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The test notification arrives after about 5 seconds; lock the device to see it on the Lock Screen. “Check Now” runs the same check as the background refresh over the open connection and reports what is new since the last check. Updates you have already seen in the app are not reported again.")
        }
    }

    private var notificationStatusTitle: LocalizedStringKey {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private func matrixToggle(_ title: LocalizedStringKey, _ systemImage: String, _ keyPath: WritableKeyPath<NotificationMatrix, Bool>, _ profile: ServerProfile) -> some View {
        Toggle(isOn: Binding(
            get: { profile.notifications[keyPath: keyPath] },
            set: { newValue in
                var matrix = profile.notifications
                matrix[keyPath: keyPath] = newValue
                manager.setNotifications(serverID, matrix)
            }
        )) {
            Label(title, systemImage: systemImage)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await manager.setBackgroundRefresh(serverID, enabled: enabled)
                if enabled { _ = await BackgroundRefresh.requestNotificationPermission() }
            } catch {
                errorMessage = error.localizedDescription
            }
            await loadStatus()
        }
    }

    private func loadStatus() async {
        notificationStatus = await BackgroundRefresh.notificationStatus()
        notificationsDenied = notificationStatus == .denied
        let state = await manager.backgroundState?.state(for: serverID)
        paused = state?.pausedForLogin ?? false
        lastRun = state?.lastRun
    }
}

/// App-wide options for the notifications of the background refresh.
struct NotificationOptionsSection: View {
    @AppStorage(NotificationPreferences.volumeThresholdKey) private var volumeThreshold = HealthEventDetector.defaultVolumeFullThreshold
    @AppStorage(NotificationPreferences.quietHoursEnabledKey) private var quietHours = false
    @AppStorage(NotificationPreferences.quietHoursStartKey) private var quietStart = NotificationPreferences.defaultQuietStart
    @AppStorage(NotificationPreferences.quietHoursEndKey) private var quietEnd = NotificationPreferences.defaultQuietEnd

    var body: some View {
        Section {
            Picker(selection: $volumeThreshold) {
                ForEach(NotificationPreferences.volumeThresholds, id: \.self) { value in
                    Text(value, format: .percent.precision(.fractionLength(0))).tag(value)
                }
            } label: {
                Label("Volume Warning Above", systemImage: "chart.pie")
            }
            Toggle(isOn: $quietHours.animation()) {
                Label("Quiet Hours", systemImage: "moon")
            }
            if quietHours {
                DatePicker("From", selection: time($quietStart), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: time($quietEnd), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Notification Options")
        } footer: {
            Text("During quiet hours notifications arrive silently and do not light up the screen. Nothing is held back.")
        }
    }

    /// Minutes since midnight ↔ a date of today for the picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: { calendar.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: { minutes.wrappedValue = calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
        )
    }
}

/// Which external app opens shells (Proxmox host and guests). `ssh://` links are understood by
/// WebSSH, Termius, Blink, Prompt and others; a template covers apps with their own scheme.
struct TerminalAppSection: View {
    @AppStorage(SSHLink.templateKey) private var template = SSHLink.defaultTemplate
    @AppStorage(SSHLink.userKey) private var user = SSHLink.defaultUser
    @AppStorage(SSHLink.portKey) private var port = SSHLink.defaultPort
    @State private var testFailed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            TextField("User", text: $user, prompt: Text("root"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            TextField("Link template", text: $template, prompt: Text(SSHLink.defaultTemplate))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.callout.monospaced())
            Button("Test with example.local", systemImage: "terminal") {
                guard let url = SSHLink.url(host: "example.local") else { testFailed = true; return }
                openURL(url) { accepted in testFailed = !accepted }
            }
        } header: {
            Text("Terminal App")
        } footer: {
            if testFailed {
                Text("No installed app accepts this link. Install a terminal app such as WebSSH, Termius or Blink, or adjust the template.")
                    .foregroundStyle(.orange)
            } else {
                Text("“Open Shell” on a Proxmox host or guest hands the connection to another app through this link. Placeholders: {user}, {host}, {port}. The default ssh://{user}@{host}:{port} is understood by WebSSH, Termius, Blink and Prompt.")
            }
        }
    }
}
