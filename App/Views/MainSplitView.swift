import SwiftUI
import BackupFeature
import SnapshotsFeature
import ContainersFeature
import ControlPanelFeature
import DashboardFeature
import DemoBackend
import DesignSystem
import Domain
import FilesFeature
import InboxFeature
import LogsFeature
import PackagesFeature
import SecurityAdvisorFeature
import UpdatesFeature
import VirtualMachinesFeature

enum SidebarItem: Hashable {
    case all
    case updates
    case notifications
    case server(ServerID)
}

enum ServerSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, virtualMachines, packages, containers, files, backup, snapshots, security, logs, controlPanel

    var id: Self { self }

    func title(for kind: BackendKind) -> LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .virtualMachines: kind == .proxmox ? "VMs & Containers" : "Virtual Machines"
        case .packages: "Packages"
        case .containers: "Containers"
        case .files: "File Station"
        case .backup: kind == .proxmox ? "Backups" : "Hyper Backup"
        case .snapshots: "Snapshot Replication"
        case .security: "Security Advisor"
        case .logs: "Logs"
        case .controlPanel: kind == .proxmox ? "Host" : "Control Panel"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .virtualMachines: "desktopcomputer"
        case .packages: "shippingbox"
        case .containers: "square.stack.3d.up"
        case .files: "folder"
        case .backup: "clock.arrow.circlepath"
        case .snapshots: "camera.on.rectangle"
        case .security: "checkmark.shield"
        case .logs: "list.bullet.rectangle"
        case .controlPanel: "slider.horizontal.3"
        }
    }

    /// Filled symbol and colour for the icon badge.
    var badgeSymbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .virtualMachines: "desktopcomputer"
        case .packages: "shippingbox.fill"
        case .containers: "square.stack.3d.up.fill"
        case .files: "folder.fill"
        case .backup: "clock.arrow.circlepath"
        case .snapshots: "camera.on.rectangle.fill"
        case .security: "checkmark.shield.fill"
        case .logs: "list.bullet.rectangle.fill"
        case .controlPanel: "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .dashboard: .blue
        case .virtualMachines: .purple
        case .packages: .orange
        case .containers: .purple
        case .files: .cyan
        case .backup: .green
        case .snapshots: .teal
        case .security: .red
        case .logs: .gray
        case .controlPanel: .indigo
        }
    }

    func subtitle(for kind: BackendKind) -> LocalizedStringKey {
        switch self {
        case .dashboard: "Live load, storage and drives"
        case .virtualMachines: kind == .proxmox ? "VMs and containers: start, stop, reboot" : "Virtual Machine Manager: start, stop, reboot"
        case .packages: "Update, start and stop"
        case .containers: "Containers and Compose projects"
        case .files: "Browse, copy, move and delete"
        case .backup: kind == .proxmox ? "Backup jobs, last runs, back up now" : "Backup tasks, back up now"
        case .snapshots: "Snapshots and replication"
        case .security: "Results of the last scan"
        case .logs: kind == .proxmox ? "Journal and sign-ins" : "System and connection logs"
        case .controlPanel: kind == .proxmox ? "Restart and shut down" : "Updates, accounts, SSH, power"
        }
    }

    var capability: Capability {
        switch self {
        case .dashboard: .dashboard
        case .virtualMachines: .vms
        case .packages: .packages
        case .containers: .containers
        case .files: .files
        case .backup: .backup
        case .snapshots: .snapshots
        case .security: .securityAdvisor
        case .logs: .logs
        case .controlPanel: .settings
        }
    }
}

struct MainSplitView: View {
    let manager: ConnectionManager

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SidebarItem? = .all
    @State private var section: ServerSection?
    @State private var showAddServer = false
    @State private var showSettings = false
    @State private var serverToRemove: ServerProfile?
    @State private var showActivity = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .onChange(of: selection) {
            // iPad: open the dashboard right away. iPhone: let the user pick the section.
            if case .server = selection, sizeClass == .regular {
                section = .dashboard
            } else {
                section = nil
            }
        }
        // A tapped notification or widget.
        .onChange(of: app.pendingRoute, initial: true) {
            guard let route = app.pendingRoute, !manager.isDemo else { return }
            app.pendingRoute = nil
            switch route {
            case .updates:
                selection = .updates
            case .server(let id):
                if manager.profile(id) != nil { selection = .server(id) }
            }
        }
        .task { await openScreenshotScreen() }
        // Overview polls every 30 s while the app is active.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await manager.refreshOverview()
            }
        }
        .sheet(item: Binding(
            get: { manager.prompts.first },
            set: { newValue in
                if newValue == nil, let first = manager.prompts.first { manager.dismissPrompt(first) }
            }
        )) { prompt in
            PromptView(manager: manager, prompt: prompt)
        }
        .sheet(isPresented: $showAddServer) {
            AddServerView(manager: manager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showActivity) {
            ActivityView()
        }
        .environment(manager.operations)
        .alert("Session ended", isPresented: Binding(
            get: { manager.interruptedSessionServer != nil },
            set: { if !$0 { manager.interruptedSessionServer = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The NAS ended the session because the same account signed in elsewhere. NAS Cockpit signed in again.")
        }
        .confirmationDialog(
            "Remove \(serverToRemove?.name ?? "")?",
            isPresented: Binding(get: { serverToRemove != nil }, set: { if !$0 { serverToRemove = nil } }),
            titleVisibility: .visible,
            presenting: serverToRemove
        ) { profile in
            Button("Remove NAS", role: .destructive) {
                if selection == .server(profile.id) { selection = .all }
                Task { await manager.remove(profile.id) }
            }
        } message: { _ in
            Text("Signs out and deletes the saved password, device token and certificate pin from this device. Nothing on the NAS is changed.")
        }
    }

    /// Debug builds only: opens the screen that `-screenshot` asked for.
    private func openScreenshotScreen() async {
        guard let screen = app.screenshotScreen else { return }
        let target: (SidebarItem, ServerSection?) = switch screen {
        case .welcome, .overview: (.all, nil)
        case .updates: (.updates, nil)
        case .notifications: (.notifications, nil)
        case .server: (.server(DemoData.homeID), nil)
        case .dashboard: (.server(DemoData.homeID), .dashboard)
        case .containers: (.server(DemoData.homeID), .containers)
        case .files: (.server(DemoData.homeID), .files)
        case .packages: (.server(DemoData.homeID), .packages)
        case .backup: (.server(DemoData.homeID), .backup)
        case .guests: (.server(DemoData.proxmoxID), .virtualMachines)
        }
        // Wait for the demo servers to connect (one of them stays unreachable), so the sections are there.
        for _ in 0..<40 where manager.profiles.filter({ manager.runtime[$0.id]?.state.isConnected == true }).count < 3 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        selection = target.0
        guard let section = target.1 else { return }
        // `onChange(of: selection)` resets the section first.
        try? await Task.sleep(for: .milliseconds(600))
        self.section = section
    }

    // MARK: Columns

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarItem.all) {
                    BadgeLabel("All NAS", systemImage: "square.grid.2x2.fill", color: .indigo)
                }
                NavigationLink(value: SidebarItem.updates) {
                    BadgeLabel("Updates", systemImage: "arrow.down.circle.fill", color: .blue)
                }
                .badge(manager.totalPendingUpdates)
                NavigationLink(value: SidebarItem.notifications) {
                    BadgeLabel("Notifications", systemImage: "bell.fill", color: .red)
                }
            }
            Section("Servers") {
                ForEach(manager.profiles) { profile in
                    NavigationLink(value: SidebarItem.server(profile.id)) {
                        ServerRowView(model: manager.tileModel(for: profile)) { selection = .updates }
                    }
                    .contextMenu {
                        Button("Reconnect", systemImage: "arrow.clockwise") {
                            Task { await manager.connect(profile.id, interactive: true) }
                        }
                        if profile.wakeOnLAN != nil, manager.runtime[profile.id]?.state.isConnected != true {
                            Button("Wake Up", systemImage: "power") {
                                Task { await manager.wake(profile.id) }
                            }
                        }
                        if !manager.isDemo {
                            Button("Remove…", systemImage: "trash", role: .destructive) {
                                serverToRemove = profile
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(manager.isDemo && app.screenshotScreen == nil ? "Demo" : "NAS Cockpit")
        .refreshable {
            await manager.connectAll()
            await manager.refreshOverview()
            await manager.refreshAllUpdates()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
            ToolbarItem(placement: .topBarLeading) {
                ActivityButton(operations: manager.operations) { showActivity = true }
            }
            ToolbarItem(placement: .primaryAction) {
                if manager.isDemo, app.screenshotScreen == nil {
                    Button("Exit Demo") { Task { await app.exitDemo() } }
                } else {
                    Button("Add Server", systemImage: "plus") { showAddServer = true }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await manager.refreshOverview()
                        await manager.refreshAllUpdates()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch selection {
        case .all, nil:
            AllServersView(manager: manager, onUpdates: { selection = .updates }) { selection = .server($0) }
        case .updates:
            UpdatesView(sources: manager.updateSources)
                .id(manager.updateSources.map(\.id))
        case .notifications:
            InboxView(sources: manager.inboxSources)
                .id(manager.inboxSources.map(\.id))
        case .server(let id):
            if let profile = manager.profile(id) {
                ServerSectionsView(manager: manager, profile: profile, selection: $section)
            } else {
                ContentUnavailableView("NAS removed", systemImage: "externaldrive.badge.xmark")
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if case .server(let id) = selection, let section, let backend = manager.backend(for: id), let profile = manager.profile(id) {
            NavigationStack {
                Group {
                    switch section {
                    case .dashboard: DashboardView(backend: backend, serverName: profile.name)
                    case .virtualMachines: GuestsView(backend: backend, serverName: profile.name, title: section.title(for: profile.backend),
                                                                  shellHost: profile.backend == .proxmox ? profile.shellHost : nil)
                    case .packages: PackagesView(backend: backend, serverName: profile.name)
                    case .containers: ContainersView(backend: backend, serverName: profile.name)
                    case .files: FileBrowserView(backend: backend, serverName: profile.name)
                    case .backup:
                        BackupView(backend: backend, serverName: profile.name,
                                   showsLogs: manager.runtime[id]?.capabilities.contains(.backupLogs) ?? false,
                                   product: profile.backend == .proxmox ? .proxmox : .hyperBackup)
                    case .snapshots:
                        SnapshotsView(backend: backend, serverName: profile.name, capabilities: manager.runtime[id]?.capabilities ?? [])
                    case .security:
                        SecurityAdvisorView(backend: backend, serverName: profile.name)
                    case .logs:
                        LogsView(backend: backend, sources: (manager.runtime[id]?.capabilities.contains(.backupLogs) ?? false)
                                 ? [.system, .connection, .backup] : [.system, .connection],
                                 backupTitle: profile.backend == .proxmox ? "Backup tasks" : "Hyper Backup")
                    case .controlPanel:
                        ControlPanelView(backend: backend, serverName: profile.name, capabilities: manager.runtime[id]?.capabilities ?? [])
                    }
                }
                .id("\(id)-\(section.rawValue)")
            }
        } else {
            ContentUnavailableView("Select a NAS", systemImage: "externaldrive", description: Text("Choose a NAS and an area to see details."))
        }
    }
}

/// Column 2 for one NAS: connection status and the areas it supports.
struct ServerSectionsView: View {
    let manager: ConnectionManager
    let profile: ServerProfile
    @Binding var selection: ServerSection?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let runtime = manager.runtime[profile.id] ?? ConnectionManager.Runtime()
        List(selection: $selection) {
            Section {
                ServerHeroCard(model: manager.tileModel(for: profile), subtitle: heroSubtitle(runtime))
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            if !runtime.state.isConnected {
                Section {
                    ConnectionStatusRow(manager: manager, profile: profile, state: runtime.state)
                }
            }
            if runtime.state.isConnected {
                Section {
                    ForEach(ServerSection.allCases.filter { runtime.capabilities.contains($0.capability) }) { section in
                        NavigationLink(value: section) {
                            BadgeLabel(section.title(for: profile.backend), systemImage: section.badgeSymbol, color: section.color, subtitle: Text(section.subtitle(for: profile.backend)))
                                .padding(.vertical, 2)
                        }
                    }
                }
                if profile.backend == .proxmox, let host = shellHost {
                    Section {
                        Button {
                            if let url = SSHLink.url(host: host) { openURL(url) }
                        } label: {
                            BadgeLabel("Open Shell", systemImage: "terminal.fill", color: .black, subtitle: Text(verbatim: host))
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("Opens the host in the terminal app set under Settings → Terminal App.")
                    }
                }
                if let snapshot = runtime.snapshot {
                    Section("System") {
                        LabeledContent("Model", value: snapshot.model)
                        LabeledContent("Version", value: snapshot.osVersion)
                        if let uptime = snapshot.uptime {
                            LabeledContent("Uptime", value: Format.duration(uptime))
                        }
                        if let temperature = snapshot.temperature {
                            LabeledContent("Temperature", value: Format.temperature(temperature))
                        }
                        Button { showWakeSetup = true } label: {
                            LabeledContent("Wake-on-LAN") {
                                Text(profile.wakeOnLAN.map { $0.mac.description } ?? String(localized: "Not set up"))
                                    .monospaced(profile.wakeOnLAN != nil)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWakeSetup) {
            WakeOnLANSetupView(manager: manager, profile: profile)
        }
    }

    @State private var showWakeSetup = false

    private var shellHost: String? { profile.shellHost }

    private func heroSubtitle(_ runtime: ConnectionManager.Runtime) -> String? {
        guard let snapshot = runtime.snapshot else { return nil }
        return "\(snapshot.model) · \(snapshot.osVersion)"
    }
}

/// Toolbar button that shows how many write operations are running.
struct ActivityButton: View {
    let operations: OperationCenter
    let action: () -> Void

    var body: some View {
        let running = operations.active.count
        Button(action: action) {
            if running > 0 {
                Label("Activity (\(running) running)", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .symbolEffect(.rotate, isActive: true)
            } else {
                Label("Activity", systemImage: "checklist")
            }
        }
        .badge(running)
    }
}

struct ConnectionStatusRow: View {
    let manager: ConnectionManager
    let profile: ServerProfile
    let state: ConnectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine(status: manager.tileModel(for: profile).status, lastReached: manager.runtime[profile.id]?.lastReached)
            if case .failed(let error) = state {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    if error == .openIDSignInRequired {
                        Button("Sign In") { Task { await manager.connect(profile.id, interactive: true) } }
                    } else if error == .passwordRequired || (error == .credentialsUnavailable && !profile.savesPassword) {
                        Button("Sign In") { manager.requestPassword(for: profile.id) }
                    } else {
                        Button("Try Again") { Task { await manager.connect(profile.id, interactive: true) } }
                        if error == .unreachable || error == .timeout {
                            WakeButton(manager: manager, profile: profile)
                        }
                    }
                }
                .buttonStyle(.bordered)
                if error == .unreachable || error == .timeout {
                    WakeStatus(manager: manager, profile: profile)
                }
            } else if state == .disconnected {
                HStack {
                    Button("Connect") { Task { await manager.connect(profile.id, interactive: true) } }
                    WakeButton(manager: manager, profile: profile)
                }
                .buttonStyle(.bordered)
                WakeStatus(manager: manager, profile: profile)
            } else if state == .needsOTP {
                Button("Enter Code") { manager.requestOTP(for: profile.id) }
                    .buttonStyle(.bordered)
            } else if state == .rebooting {
                Label("The NAS is restarting. The app signs in again as soon as it answers.", systemImage: "arrow.clockwise.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AllServersView: View {
    let manager: ConnectionManager
    var onUpdates: () -> Void = {}
    let onSelect: (ServerID) -> Void

    var body: some View {
        ScrollView {
            OverviewSummary(manager: manager, onUpdates: onUpdates)
                .padding(.horizontal)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(manager.profiles) { profile in
                    Button {
                        onSelect(profile.id)
                    } label: {
                        ServerTileView(model: manager.tileModel(for: profile), onUpdates: onUpdates)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("All NAS")
        .refreshable { await manager.refreshOverview() }
    }
}

/// "2 of 3 online · 6 updates · 1 warning" at the top of All NAS.
struct OverviewSummary: View {
    let manager: ConnectionManager
    var onUpdates: () -> Void = {}

    var body: some View {
        let tiles = manager.profiles.map { manager.tileModel(for: $0) }
        let online = tiles.filter { $0.status == .online }.count
        let warnings = tiles.filter(\.hasStorageProblem).count
        HStack(spacing: 10) {
            SummaryPill(value: "\(online)/\(tiles.count)", title: "Online", systemImage: "checkmark.circle.fill", color: online == tiles.count ? .green : .orange)
            Button(action: onUpdates) {
                SummaryPill(value: "\(manager.totalPendingUpdates)", title: "Updates", systemImage: "arrow.down.circle.fill", color: .blue)
            }
            .buttonStyle(.plain)
            SummaryPill(value: "\(warnings)", title: "Warnings", systemImage: "exclamationmark.triangle.fill", color: warnings == 0 ? .gray : .red)
        }
    }
}

struct SummaryPill: View {
    let value: String
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

extension ServerProfile {
    /// The address the app reached last (or the first one), for ssh:// links.
    var shellHost: String? {
        (addresses.first { $0.id == lastReachedAddressID } ?? addresses.first)?.host
    }
}
