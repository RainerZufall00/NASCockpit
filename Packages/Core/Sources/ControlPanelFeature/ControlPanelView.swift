import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

/// A settings change waiting for confirmation. The dialog names the change and the NAS.
enum ControlPanelChange: Identifiable, Equatable {
    case updatePolicy(UpdatePolicy)
    case ssh(Bool)
    case power(PowerAction)

    var id: String {
        switch self {
        case .updatePolicy(let policy): "policy/\(policy.rawValue)"
        case .ssh(let on): "ssh/\(on)"
        case .power(let action): "power/\(action.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .updatePolicy: String(localized: "Change DSM update setting?")
        case .ssh(true): String(localized: "Turn on SSH?")
        case .ssh(false): String(localized: "Turn off SSH?")
        case .power(.restart): String(localized: "Restart NAS?")
        case .power(.shutDown): String(localized: "Shut down NAS?")
        }
    }

    var confirmTitle: String {
        switch self {
        case .updatePolicy: String(localized: "Change")
        case .ssh(true): String(localized: "Turn On")
        case .ssh(false): String(localized: "Turn Off")
        case .power(.restart): String(localized: "Restart")
        case .power(.shutDown): String(localized: "Shut Down")
        }
    }

    var isDestructive: Bool {
        if case .power = self { return true }
        return false
    }

    func message(serverName: String) -> String {
        switch self {
        case .updatePolicy(let policy):
            String(localized: "“\(serverName)” will use: \(policy.title).")
        case .ssh(true):
            String(localized: "SSH will be turned on for “\(serverName)”. Turn it on only while you need it and never forward the SSH port to the internet.")
        case .ssh(false):
            String(localized: "SSH will be turned off for “\(serverName)”. Open SSH sessions are ended.")
        case .power(.restart):
            String(localized: "“\(serverName)” restarts and is unavailable for a few minutes. Running transfers, backups and containers are interrupted. The app reconnects automatically.")
        case .power(.shutDown):
            String(localized: "“\(serverName)” shuts down. You can only turn it on again on the device itself or with Wake on LAN.")
        }
    }
}

extension UpdatePolicy {
    var title: String {
        switch self {
        case .notifyOnly: String(localized: "Notify me only")
        case .importantOnly: String(localized: "Install important updates automatically")
        case .all: String(localized: "Install all updates automatically")
        }
    }
}

@MainActor
@Observable
final class ControlPanelModel {
    private(set) var updateSettings: UpdateSettings?
    private(set) var terminal: TerminalSettings?
    private(set) var users: [NASUser] = []
    private(set) var isLoading = false
    private(set) var savingChange: ControlPanelChange?
    var errorMessage: String?

    @ObservationIgnored let backend: any ServerBackend
    let serverName: String
    let capabilities: Set<Capability>

    init(backend: any ServerBackend, serverName: String, capabilities: Set<Capability>) {
        self.backend = backend
        self.serverName = serverName
        self.capabilities = capabilities
    }

    var disabledUserCount: Int { users.filter(\.isDisabled).count }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Each area loads on its own: one unsupported API must not hide the others.
        if capabilities.contains(.updateSettings) { updateSettings = try? await backend.updateSettings() }
        if capabilities.contains(.terminal) { terminal = try? await backend.terminalSettings() }
        if capabilities.contains(.users) { users = (try? await backend.users()) ?? users }
    }

    /// Quick settings writes. Never retried; errors are shown, the value is reloaded.
    func apply(_ change: ControlPanelChange) async {
        savingChange = change
        defer { savingChange = nil }
        do {
            switch change {
            case .updatePolicy(let policy):
                try await backend.setUpdatePolicy(policy)
            case .ssh(let enabled):
                try await backend.setSSH(enabled: enabled)
            case .power:
                return
            }
        } catch {
            errorMessage = BackendError(error).localizedDescription
        }
        await load()
    }
}

public struct ControlPanelView: View {
    @State private var model: ControlPanelModel
    @State private var pending: ControlPanelChange?
    @Environment(OperationCenter.self) private var center

    public init(backend: any ServerBackend, serverName: String, capabilities: Set<Capability>) {
        _model = State(initialValue: ControlPanelModel(backend: backend, serverName: serverName, capabilities: capabilities))
    }

    private var has: Set<Capability> { model.capabilities }

    public var body: some View {
        List {
            if has.contains(.updateSettings) {
                updatesSection
            }
            if has.contains(.users) || has.contains(.connections) {
                Section {
                    if has.contains(.users) {
                        NavigationLink {
                            UsersView(backend: model.backend, serverName: model.serverName)
                        } label: {
                            BadgeLabel("Users", systemImage: "person.2.fill", color: .blue, subtitle: usersSummary)
                        }
                    }
                    if has.contains(.connections) {
                        NavigationLink {
                            ConnectionsView(backend: model.backend)
                        } label: {
                            BadgeLabel("Signed In Now", systemImage: "person.badge.clock.fill", color: .teal, subtitle: Text("Who is using the NAS right now"))
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Disable an account if a device was lost or a password may be known to others.")
                }
            }
            if has.contains(.terminal), let terminal = model.terminal {
                Section {
                    Toggle(isOn: Binding(get: { terminal.sshEnabled }, set: { pending = .ssh($0) })) {
                        BadgeLabel("SSH", systemImage: "terminal.fill", color: terminal.sshEnabled ? .orange : .gray,
                                   subtitle: Text(terminal.sshEnabled ? "On" : "Off"))
                    }
                    .disabled(model.savingChange != nil)
                    .confirmation(for: pending, matching: { if case .ssh = $0 { true } else { false } }, serverName: model.serverName, clear: { pending = nil }, run: run)
                } header: {
                    Text("Terminal")
                } footer: {
                    if let port = terminal.sshPort, terminal.sshEnabled {
                        Text("SSH listens on port \(String(port)). Turn it off when you no longer need it.")
                    }
                }
            }
            if has.contains(.power) {
                powerSection
            }
        }
        .overlay {
            if model.isLoading, model.updateSettings == nil, model.terminal == nil, model.users.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("Control Panel")
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("Change failed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var updatesSection: some View {
        Section {
            if let settings = model.updateSettings {
                BadgeLabel("Automatic Updates", systemImage: "arrow.down.circle.fill", color: .blue,
                           subtitle: settings.schedule.flatMap { settings.policy == .notifyOnly ? nil : Text("Checks \($0)") })
                Picker(selection: Binding(get: { settings.policy }, set: { if $0 != settings.policy { pending = .updatePolicy($0) } })) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                } label: {
                    Label("Automatic Updates", systemImage: "arrow.down.circle")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.savingChange != nil)
                .confirmation(for: pending, matching: { if case .updatePolicy = $0 { true } else { false } }, serverName: model.serverName, clear: { pending = nil }, run: run)
            } else if !model.isLoading {
                Text("Update settings unavailable").foregroundStyle(.secondary)
            }
        } header: {
            Text("DSM Updates")
        } footer: {
            Text("Installing an available DSM update is done in Updates. The NAS restarts afterwards.")
        }
    }

    private var powerSection: some View {
        let id = model.backend.serverID
        let busy = center.isBusy(.power(.restart), on: id) || center.isBusy(.power(.shutDown), on: id)
        return Section {
            HStack(spacing: 12) {
                ForEach([PowerAction.restart, .shutDown], id: \.self) { action in
                    PowerTile(action: action, operation: center.visible(.power(action), on: id)) {
                        pending = .power(action)
                    }
                    .disabled(busy)
                    .confirmation(for: pending, matching: { $0 == .power(action) }, serverName: model.serverName, clear: { pending = nil }, run: run)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Power")
        } footer: {
            Text("Both ask for Face ID. After a restart the app signs in again on its own.")
        }
    }

    private var usersSummary: Text? {
        guard !model.users.isEmpty else { return nil }
        return model.disabledUserCount == 0
            ? Text("\(model.users.count) active")
            : Text("\(model.users.count - model.disabledUserCount) active, \(model.disabledUserCount) disabled")
    }

    private func run(_ change: ControlPanelChange) {
        switch change {
        case .power(let action):
            Task {
                // Restart and shut down always need Face ID, independent of the app lock.
                guard await center.authorize(change.title + " " + model.serverName) else { return }
                let backend = model.backend
                center.enqueue(serverID: backend.serverID, serverName: model.serverName, kind: .power(action),
                               title: action == .restart ? String(localized: "Restart") : String(localized: "Shut down")) { progress in
                    try await backend.perform(action, progress: progress)
                }
            }
        default:
            Task { await model.apply(change) }
        }
    }
}

/// Large button for restart / shut down.
struct PowerTile: View {
    let action: PowerAction
    let operation: OperationCenter.Operation?
    let onTap: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let color: Color = action == .restart ? .orange : .red
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconBadge(action == .restart ? "arrow.clockwise" : "power", color: color, size: 36)
                    Spacer()
                    if let operation { OperationStatusView(operation) }
                }
                Text(action == .restart ? "Restart" : "Shut Down")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(action == .restart ? "Back in a few minutes" : "Turn on at the device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(color.opacity(0.35), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Confirmation dialog anchored to this row (iPad shows the popover next to it).
    func confirmation(
        for pending: ControlPanelChange?,
        matching: @escaping (ControlPanelChange) -> Bool,
        serverName: String,
        clear: @escaping () -> Void,
        run: @escaping (ControlPanelChange) -> Void
    ) -> some View {
        confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending.map(matching) ?? false }, set: { if !$0 { clear() } }),
            titleVisibility: .visible,
            presenting: pending
        ) { change in
            Button(change.confirmTitle, role: change.isDestructive ? .destructive : nil) { run(change) }
        } message: { change in
            Text(change.message(serverName: serverName))
        }
    }
}

#Preview {
    NavigationStack {
        ControlPanelView(backend: MockBackend.preview(), serverName: "Home NAS", capabilities: [.updateSettings, .users, .terminal, .power, .connections])
    }
    .environment(OperationCenter())
}
