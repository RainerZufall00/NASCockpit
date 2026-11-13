import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

@MainActor
@Observable
public final class GuestsViewModel {
    public private(set) var guests: [VirtualGuest] = []
    public private(set) var isLoading = false
    public private(set) var error: BackendError?
    public private(set) var denied: Set<WriteAction> = []
    public var searchText = ""

    @ObservationIgnored let backend: any ServerBackend
    public let serverName: String

    public init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    public var serverID: ServerID { backend.serverID }

    public var filtered: [VirtualGuest] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return guests }
        return guests.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.vmid).contains(query)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Guests grouped by node, nodes sorted by name. One section when everything runs on one node.
    public var byNode: [(node: String, guests: [VirtualGuest])] {
        Dictionary(grouping: filtered, by: \.node)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    public var runningCount: Int { guests.filter(\.status.isRunning).count }
    public var vmCount: Int { guests.filter { $0.kind == .virtualMachine && !$0.isTemplate }.count }
    public var containerCount: Int { guests.filter { $0.kind == .container && !$0.isTemplate }.count }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guests = try await backend.guests()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        denied = await backend.deniedActions()
    }

    /// Refreshes while a guest is between states, so CPU and uptime move.
    public func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

/// A guest action waiting for confirmation.
struct PendingGuestAction: Identifiable, Equatable {
    let action: GuestAction
    let guest: VirtualGuest

    var id: String { "\(action.rawValue)/\(guest.id)" }

    var title: String {
        switch action {
        case .start: String(localized: "Start \(guest.name)")
        case .shutdown: String(localized: "Shut down \(guest.name)")
        case .stop: String(localized: "Stop \(guest.name)")
        case .reboot: String(localized: "Reboot \(guest.name)")
        }
    }

    var confirmTitle: LocalizedStringKey {
        switch action {
        case .start: "Start"
        case .shutdown: "Shut Down"
        case .stop: "Stop"
        case .reboot: "Reboot"
        }
    }

    var isDisruptive: Bool { action != .start }

    func message(serverName: String) -> String {
        let what = guest.kind == .virtualMachine ? String(localized: "VM") : String(localized: "container")
        switch action {
        case .start:
            return String(localized: "The \(what) “\(guest.name)” (\(String(guest.vmid))) will be started on “\(serverName)”.")
        case .shutdown:
            return String(localized: "The \(what) “\(guest.name)” (\(String(guest.vmid))) is asked to shut down cleanly. If the guest ignores the request, use Stop.")
        case .stop:
            return String(localized: "The \(what) “\(guest.name)” (\(String(guest.vmid))) is powered off immediately, like pulling the plug. Unsaved data inside the guest is lost.")
        case .reboot:
            return String(localized: "The \(what) “\(guest.name)” (\(String(guest.vmid))) shuts down cleanly and starts again.")
        }
    }

    var systemImage: String {
        switch action {
        case .start: "play.circle"
        case .shutdown: "power.circle"
        case .stop: "stop.circle"
        case .reboot: "arrow.clockwise"
        }
    }

    var tint: Color {
        switch action {
        case .start: .green
        case .shutdown: .orange
        case .stop: .red
        case .reboot: .blue
        }
    }
}

public struct GuestsView: View {
    @State private var model: GuestsViewModel
    @State private var pending: PendingGuestAction?
    @Environment(OperationCenter.self) private var center
    private let title: LocalizedStringKey
    private let shellHost: String?

    /// `title`: "VMs & Containers" on Proxmox (QEMU and LXC), "Virtual Machines" on Synology VMM.
    /// `shellHost`: address of the Proxmox host; enables "Open via Host" (`pct enter`) for containers.
    public init(backend: any ServerBackend, serverName: String, title: LocalizedStringKey = "VMs & Containers", shellHost: String? = nil) {
        _model = State(initialValue: GuestsViewModel(backend: backend, serverName: serverName))
        self.title = title
        self.shellHost = shellHost
    }

    public var body: some View {
        List {
            if !model.guests.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        StatTile(value: model.runningCount, title: "Running", systemImage: "play.circle.fill", color: .green)
                        StatTile(value: model.vmCount, title: "VMs", systemImage: "desktopcomputer", color: .blue)
                        StatTile(value: model.containerCount, title: "Containers", systemImage: "shippingbox.fill", color: .purple)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            let groups = model.byNode
            ForEach(groups, id: \.node) { group in
                Section {
                    ForEach(group.guests) { guestRow($0) }
                } header: {
                    if groups.count > 1 { Text(verbatim: group.node) } else { Text("Guests") }
                }
            }
        }
        .overlay {
            if model.guests.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Guests unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No guests", systemImage: "desktopcomputer", description: Text("Create VMs or containers on the host."))
                }
            } else if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .searchable(text: $model.searchText, prompt: Text("Search by name, ID or tag"))
        .navigationTitle(title)
        .refreshable { await model.load() }
        .task { await model.load() }
        .task { await model.pollWhileVisible() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    private func guestRow(_ guest: VirtualGuest) -> some View {
        let kinds = GuestAction.allCases.map { OperationCenter.Kind.guest($0, id: guest.id) }
        let busy = kinds.contains { center.isBusy($0, on: model.serverID) }
        let operation = kinds.compactMap { center.visible($0, on: model.serverID) }.max { $0.createdAt < $1.createdAt }
        let allowed = !model.denied.contains(.guestControl)
        let actions = allowed && !busy ? GuestAction.available(for: guest) : []
        return NavigationLink {
            GuestDetailView(backend: model.backend, guest: guest, serverName: model.serverName, actions: actions, shellHost: shellHost, run: run)
        } label: {
            GuestRow(guest: guest, operation: operation)
        }
        .swipeActions(edge: .trailing) { buttons(guest, actions) }
        .contextMenu { buttons(guest, actions) }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending?.guest.id == guest.id }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: action.isDisruptive ? .destructive : nil) { run(action) }
        } message: { action in
            Text(action.message(serverName: model.serverName))
        }
    }

    @ViewBuilder
    private func buttons(_ guest: VirtualGuest, _ actions: [GuestAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            let item = PendingGuestAction(action: action, guest: guest)
            Button(item.confirmTitle, systemImage: item.systemImage) { pending = item }
                .tint(item.tint)
        }
    }

    private func run(_ item: PendingGuestAction) {
        let backend = model.backend
        center.enqueue(serverID: model.serverID, serverName: model.serverName, kind: .guest(item.action, id: item.guest.id), title: item.title) { progress in
            try await backend.perform(item.action, guest: item.guest, progress: progress)
        }
    }
}

struct GuestRow: View {
    let guest: VirtualGuest
    var operation: OperationCenter.Operation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(guest.kind == .virtualMachine ? "desktopcomputer" : "shippingbox.fill", color: badgeColor, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                (Text(guest.name).font(.body.weight(.medium))
                    + Text(verbatim: "  \(guest.vmid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary))
                    .lineLimit(2)
                Text(metrics.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !guest.tags.isEmpty {
                    Text(guest.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                OperationErrorText(operation)
            }
            Spacer(minLength: 6)
            if let operation, !operation.status.isFinished {
                OperationStatusView(operation)
            } else {
                GuestStatusChip(guest: guest).fixedSize()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "CPU 9 % · 1.9 GB · up 22d" – what matters for a running guest; the size for a stopped one.
    private var metrics: [String] {
        var parts: [String] = []
        if guest.isTemplate {
            parts.append(String(localized: "Template"))
        } else if guest.status.isRunning {
            if let cpu = guest.cpuLoad { parts.append(String(localized: "CPU \(Format.percent(cpu))")) }
            if let memory = guest.memoryBytes { parts.append(Format.memory(memory)) }
            if let uptime = guest.uptime { parts.append(String(localized: "up \(Format.duration(uptime))")) }
        } else if let max = guest.maxMemoryBytes {
            parts.append(Format.memory(max))
        }
        if let lock = guest.lock { parts.append(String(localized: "locked: \(lock)")) }
        return parts
    }

    private var badgeColor: Color {
        if guest.isTemplate { return .gray }
        switch guest.status {
        case .running: return guest.kind == .virtualMachine ? .blue : .purple
        case .paused, .suspended: return .orange
        default: return .gray
        }
    }
}

struct GuestStatusChip: View {
    let guest: VirtualGuest

    var body: some View {
        StatusChip(title, color: color)
    }

    private var title: LocalizedStringKey {
        if guest.isTemplate { return "Template" }
        switch guest.status {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .suspended: return "Suspended"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        if guest.isTemplate { return .secondary }
        switch guest.status {
        case .running: return .green
        case .paused, .suspended: return .orange
        default: return .secondary
        }
    }
}

/// Facts about one guest plus the actions that fit its state.
struct GuestDetailView: View {
    let backend: any ServerBackend
    let guest: VirtualGuest
    let serverName: String
    let actions: [GuestAction]
    var shellHost: String?
    let run: (PendingGuestAction) -> Void

    @State private var addresses: [String]?
    @State private var supportsSnapshots = false
    // The list's dialog sits on a row that is off screen while this page is shown: ask here.
    @State private var pending: PendingGuestAction?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    IconBadge(guest.kind == .virtualMachine ? "desktopcomputer" : "shippingbox.fill",
                              color: guest.status.isRunning ? (guest.kind == .virtualMachine ? .blue : .purple) : .gray, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guest.name).font(.title3.weight(.semibold))
                        Text(guest.kind == .virtualMachine ? "Virtual machine \(String(guest.vmid)) on \(guest.node)" : "Container \(String(guest.vmid)) on \(guest.node)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    GuestStatusChip(guest: guest)
                }
                .padding(.vertical, 4)
            }
            if !actions.isEmpty {
                Section("Actions") {
                    ForEach(actions, id: \.self) { action in
                        let item = PendingGuestAction(action: action, guest: guest)
                        Button {
                            pending = item
                        } label: {
                            Label(item.confirmTitle, systemImage: item.systemImage)
                                .foregroundStyle(item.tint)
                        }
                    }
                }
                .confirmationDialog(
                    pending?.title ?? "",
                    isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                    titleVisibility: .visible,
                    presenting: pending
                ) { item in
                    Button(item.confirmTitle, role: item.isDisruptive ? .destructive : nil) { run(item) }
                } message: { item in
                    Text(item.message(serverName: serverName))
                }
            }
            if supportsSnapshots, !guest.isTemplate {
                Section {
                    NavigationLink {
                        GuestSnapshotsView(backend: backend, guest: guest, serverName: serverName)
                    } label: {
                        Label("Snapshots", systemImage: "camera.on.rectangle")
                    }
                } footer: {
                    Text("Take a snapshot before an update; roll back if something breaks.")
                }
            }
            if guest.status.isRunning {
                Section {
                    if guest.kind == .container, let shellHost {
                        HostShellRow(guest: guest, host: shellHost, backend: backend, openURL: openURL)
                        HostShellExplanation(guest: guest, host: shellHost)
                    }
                    ShellButtons(addresses: addresses, openURL: openURL)
                } header: {
                    Text("Shell")
                } footer: {
                    if guest.kind == .container, shellHost != nil {
                        Text("“Open via Host” works without an SSH server in the container. The address buttons connect to the container directly and need one.")
                    } else if addresses?.isEmpty == true {
                        Text(guest.kind == .virtualMachine
                             ? "No IP address known. Proxmox reports it only when the QEMU guest agent runs in the VM; Synology VMM does not report addresses."
                             : "No IP address known for this container.")
                    } else {
                        Text("Opens the terminal app set under Settings → Terminal App (ssh:// link).")
                    }
                }
                .task(id: guest.id) { addresses = (try? await backend.guestAddresses(guest)) ?? [] }
            }
            Section("Resources") {
                if let cores = guest.cores { LabeledContent("Cores", value: String(cores)) }
                if let cpu = guest.cpuLoad, guest.status.isRunning { LabeledContent("CPU", value: Format.percent(cpu)) }
                if let max = guest.maxMemoryBytes {
                    if let used = guest.memoryBytes, guest.status.isRunning {
                        LabeledContent("Memory", value: "\(Format.memory(used)) / \(Format.memory(max))")
                    } else {
                        LabeledContent("Memory", value: Format.memory(max))
                    }
                }
                if let disk = guest.maxDiskBytes, disk > 0 { LabeledContent("Disk", value: Format.bytes(disk)) }
                if let uptime = guest.uptime { LabeledContent("Uptime", value: Format.duration(uptime)) }
                if let ha = guest.haState { LabeledContent("HA state", value: ha) }
                if let lock = guest.lock { LabeledContent("Locked by", value: lock) }
                if !guest.tags.isEmpty { LabeledContent("Tags", value: guest.tags.joined(separator: ", ")) }
            }
        }
        .navigationTitle(guest.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { supportsSnapshots = await backend.capabilities().contains(.guestSnapshots) }
    }
}

#Preview {
    NavigationStack {
        GuestsView(backend: MockBackend.preview(DemoData.proxmoxID), serverName: "Proxmox Lab")
    }
    .environment(OperationCenter())
}

/// One "Open Shell" button per known address, or a loading row.
struct ShellButtons: View {
    let addresses: [String]?
    let openURL: OpenURLAction

    var body: some View {
        if let addresses {
            ForEach(addresses, id: \.self) { address in
                Button {
                    if let url = SSHLink.url(host: address) { openURL(url) }
                } label: {
                    Label {
                        HStack {
                            Text("Open Shell")
                            Spacer()
                            Text(verbatim: address).foregroundStyle(.secondary).font(.callout.monospaced())
                        }
                    } icon: {
                        Image(systemName: "terminal")
                    }
                }
            }
        } else {
            HStack {
                Label("Looking up addresses…", systemImage: "terminal")
                Spacer()
                ProgressView()
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// `pct enter <id>` on the Proxmox host (see `ShellCommandButton`).
struct HostShellRow: View {
    let guest: VirtualGuest
    let host: String
    let backend: any ServerBackend
    let openURL: OpenURLAction

    @State private var hostNode: String?

    private var command: String {
        HostShellCommand.enterContainer(vmid: guest.vmid, guestNode: guest.node, hostNode: hostNode, user: HostShellCommand.sshUser())
    }

    var body: some View {
        ShellCommandButton(
            "Open via Host", command: command, host: host,
            hintTitle: "Paste the command after the login",
            hintMessage: String(localized: "“\(command)” is now on the clipboard. Your terminal app connects to the Proxmox host \(host). After the login, paste the command and press Return: you are then root in “\(guest.name)”."),
            hintKey: "shell.hostHintSeen"
        )
        .task(id: guest.id) { hostNode = await backend.hostNode() }
    }
}

/// What "Open via Host" does, in plain words, folded away.
struct HostShellExplanation: View {
    let guest: VirtualGuest
    let host: String

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "The app copies the command “pct enter \(String(guest.vmid))” to the clipboard.")
                step(2, "Your terminal app (Settings → Terminal App) opens an SSH connection to the Proxmox host \(host), with the login saved in that app.")
                step(3, "You paste the command and press Return. Proxmox opens a root shell inside “\(guest.name)”. Type “exit” to get back to the host.")
                Text("The container needs no SSH server and no password, and its console auto-login is not used. If it runs on another cluster node, the command first hops there with “ssh -t <node>”; if your SSH user is not root, it starts with “sudo”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label {
                    Text("Anyone who can sign in to the host this way can enter every container as root. Protect the host login with a key or a strong password.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("How does this work?", systemImage: "info.circle")
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).").font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}
