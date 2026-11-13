import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

/// One NAS contributing to the aggregated update list.
public struct UpdateSource: Identifiable, Sendable {
    public let id: ServerID
    public let name: String
    public let iconName: String
    public let colorName: String
    public let backend: any ServerBackend
    /// Proxmox host address: updates are installed in the terminal app ("Install via Shell").
    public let shellHost: String?

    public init(id: ServerID, name: String, iconName: String, colorName: String, backend: any ServerBackend, shellHost: String? = nil) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorName = colorName
        self.backend = backend
        self.shellHost = shellHost
    }
}

@MainActor
@Observable
public final class UpdatesViewModel {
    public struct ServerUpdates: Identifiable {
        public let id: ServerID
        public let name: String
        public let iconName: String
        public let colorName: String
        /// `nil` while loading.
        public var result: Result<[UpdateItem], BackendError>?
        public var denied: Set<WriteAction> = []

        public var items: [UpdateItem] { (try? result?.get()) ?? [] }
    }

    public private(set) var groups: [ServerUpdates]
    @ObservationIgnored private let sources: [UpdateSource]

    public init(sources: [UpdateSource]) {
        self.sources = sources
        groups = sources.map { ServerUpdates(id: $0.id, name: $0.name, iconName: $0.iconName, colorName: $0.colorName, result: nil) }
    }

    public var totalCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    public var isLoading: Bool { groups.contains { $0.result == nil } }

    public func source(for id: ServerID) -> UpdateSource? {
        sources.first { $0.id == id }
    }

    /// Package updates that may be part of a bulk update (DSM updates never are).
    public var selectableItems: [UpdateItem] {
        groups.flatMap { group in
            group.denied.contains(.packageUpdate) ? [] : group.items.filter { !$0.isSystemUpdate }
        }
    }

    public func item(id: String) -> UpdateItem? {
        groups.lazy.flatMap(\.items).first { $0.id == id }
    }

    /// Servers refresh their catalogs in parallel; failures are ignored (the list shows what it can).
    public func refreshCatalogs() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                let backend = source.backend
                group.addTask { try? await backend.refreshUpdateCatalog() }
            }
        }
    }

    /// Queries all NAS in parallel; a slow or offline NAS does not block the others.
    public func load() async {
        // SwiftUI cancels `.task` when it swaps the view during navigation (e.g. jumping here from a badge)
        // without always starting it again. Run the load on its own so it finishes; a second call while
        // one is running waits for it instead of starting over.
        if let loadTask { return await loadTask.value }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private func performLoad() async {
        for index in groups.indices { groups[index].result = nil }
        await withTaskGroup(of: (ServerID, Result<[UpdateItem], BackendError>, Set<WriteAction>).self) { group in
            for source in sources {
                let backend = source.backend
                let id = source.id
                group.addTask { await Self.fetch(id, backend) }
            }
            for await (id, result, denied) in group {
                apply(id, result, denied)
            }
        }
    }

    /// Reloads one NAS without clearing its list first (after an update finished).
    public func reload(_ serverID: ServerID) async {
        guard let source = source(for: serverID) else { return }
        let (id, result, denied) = await Self.fetch(serverID, source.backend)
        apply(id, result, denied)
    }

    private func apply(_ id: ServerID, _ result: Result<[UpdateItem], BackendError>, _ denied: Set<WriteAction>) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        // A load that SwiftUI cancelled (the view was replaced while navigating) is not an error to show;
        // the load of the view that is on screen fills the list.
        if case .failure(.cancelled) = result { return }
        groups[index].result = result
        groups[index].denied = denied
    }

    nonisolated private static func fetch(_ id: ServerID, _ backend: any ServerBackend) async -> (ServerID, Result<[UpdateItem], BackendError>, Set<WriteAction>) {
        let result: Result<[UpdateItem], BackendError>
        do {
            result = .success(try await backend.updates())
        } catch {
            result = .failure(BackendError(error))
        }
        return (id, result, await backend.deniedActions())
    }
}

extension UpdateItem {
    var operationKind: OperationCenter.Kind {
        switch kind {
        case .package(let id): .packageUpdate(packageID: id)
        case .system: .systemUpdate
        }
    }

    var operationTitle: String {
        isSystemUpdate ? String(localized: "Install \(availableVersion)") : String(localized: "Update \(name)")
    }
}

public struct UpdatesView: View {
    @State private var model: UpdatesViewModel
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var showsBulkConfirmation = false
    @State private var pendingSingle: UpdateItem?
    @State private var pendingSystem: UpdateItem?
    @State private var authorizationFailed = false
    @State private var isChecking = false
    @Environment(OperationCenter.self) private var center

    public init(sources: [UpdateSource]) {
        _model = State(initialValue: UpdatesViewModel(sources: sources))
    }

    private var isEditing: Bool { editMode.isEditing }

    public var body: some View {
        List(selection: $selection) {
            ForEach(model.groups) { group in
                Section {
                    switch group.result {
                    case .none:
                        HStack {
                            ProgressView()
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    case .success(let items) where items.isEmpty:
                        Label("Up to date", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    case .success(let items):
                        ForEach(items) { row($0, in: group) }
                        if let host = model.source(for: group.id)?.shellHost, !isEditing {
                            installViaShell(host: host, group: group)
                        }
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 8) {
                        ServerIcon(systemName: group.iconName, colorName: group.colorName, size: 20)
                        Text(group.name)
                    }
                } footer: {
                    if model.source(for: group.id)?.shellHost != nil, !group.items.isEmpty {
                        Text(group.items.contains(where: \.requiresReboot)
                             ? "Proxmox cannot install updates through its API, so the app hands the command to your terminal app. A new kernel is included: restart the host afterwards (Host → Restart)."
                             : "Proxmox cannot install updates through its API, so the app hands the command to your terminal app. Afterwards, tap Check for Updates.")
                    } else if group.denied.contains(.packageUpdate), !group.items.isEmpty {
                        Text("These updates are installed on the server itself; the app only lists them.")
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if model.groups.isEmpty {
                ContentUnavailableView("No NAS connected", systemImage: "externaldrive.badge.xmark")
            }
        }
        .navigationTitle("Updates")
        .toolbar { toolbar }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: center.completedCount) {
            Task {
                for group in model.groups where !center.hasActiveOperations(on: group.id) {
                    await model.reload(group.id)
                }
            }
        }
        .sheet(isPresented: $showsBulkConfirmation) {
            BulkUpdateSheet(groups: bulkGroups) { startBulk() }
        }
        .alert("Not confirmed", isPresented: $authorizationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was started.")
        }
    }

    private func installViaShell(host: String, group: UpdatesViewModel.ServerUpdates) -> some View {
        let command = HostShellCommand.upgradeHost(user: HostShellCommand.sshUser())
        return ShellCommandButton(
            "Install via Shell", command: command, host: host,
            hintTitle: "Paste the command after the login",
            hintMessage: String(localized: "“\(command)” is now on the clipboard. Your terminal app connects to “\(group.name)” (\(host)). After the login, paste the command, press Return and confirm with “Y”. Come back afterwards and tap Check for Updates."),
            hintKey: "shell.updateHintSeen"
        )
        .selectionDisabled()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Check for Updates", systemImage: isChecking ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                checkForUpdates()
            }
            .symbolEffect(.rotate, isActive: isChecking)
            .disabled(isChecking || isEditing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(isEditing ? "Done" : "Select") {
                withAnimation {
                    editMode = isEditing ? .inactive : .active
                    if !isEditing { selection = [] }
                }
            }
            .disabled(model.selectableItems.isEmpty && !isEditing)
        }
        if isEditing {
            ToolbarItem(placement: .bottomBar) {
                Button(selection.count == selectableIDs.count ? "Deselect All" : "Select All") {
                    selection = selection.count == selectableIDs.count ? [] : selectableIDs
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(selectedItems.isEmpty ? String(localized: "Update") : String(localized: "Update (\(selectedItems.count))")) {
                    showsBulkConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedItems.isEmpty)
            }
        }
    }

    private func row(_ item: UpdateItem, in group: UpdatesViewModel.ServerUpdates) -> some View {
        let operation = center.visible(item.operationKind, on: item.serverID)
        let busy = center.isBusy(item.operationKind, on: item.serverID)
        let deniedAction: WriteAction = item.isSystemUpdate ? .systemUpdate : .packageUpdate
        let allowed = !group.denied.contains(deniedAction)
        return UpdateRow(item: item, operation: operation) {
            if !isEditing, !busy, allowed {
                Button(item.isSystemUpdate ? "Install…" : "Update") {
                    if item.isSystemUpdate { pendingSystem = item } else { pendingSingle = item }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(item.isSystemUpdate ? .orange : .blue)
            }
        }
        // Dialogs anchored to the row, so iPad shows the popover next to it.
        .confirmationDialog(
            String(localized: "Update \(item.name)?"),
            isPresented: Binding(get: { pendingSingle?.id == item.id }, set: { if !$0 { pendingSingle = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Update on “\(group.name)”")) { enqueue(item) }
        } message: {
            Text("\(item.name) on “\(group.name)” will be updated to \(item.availableVersion). The package is unavailable while it updates.")
        }
        .confirmationDialog(
            String(localized: "Install DSM update on “\(group.name)”?"),
            isPresented: Binding(get: { pendingSystem?.id == item.id }, set: { if !$0 { pendingSystem = nil } }),
            titleVisibility: .visible
        ) {
            Button("Install and Restart", role: .destructive) { startSystemUpdate(item) }
        } message: {
            Text("“\(group.name)” will install \(item.availableVersion) and restart. It is unavailable for several minutes and running transfers, backups and containers are interrupted. The app reconnects automatically.")
        }
        .tag(item.id)
        // DSM updates restart the NAS: never part of a bulk update.
        .selectionDisabled(item.isSystemUpdate || busy || !allowed)
    }

    private var selectableIDs: Set<String> {
        Set(model.selectableItems.filter { !center.isBusy($0.operationKind, on: $0.serverID) }.map(\.id))
    }

    private var selectedItems: [UpdateItem] {
        // List order, not set order: the sheet and the queue follow what the user sees.
        model.groups.flatMap(\.items).filter { selection.contains($0.id) && !$0.isSystemUpdate }
    }

    private var bulkGroups: [BulkUpdateSheet.Group] {
        model.groups.compactMap { group in
            let items = selectedItems.filter { $0.serverID == group.id }
            return items.isEmpty ? nil : BulkUpdateSheet.Group(id: group.id, name: group.name, iconName: group.iconName, colorName: group.colorName, items: items)
        }
    }

    /// Asks every server to refresh its catalog (DSM package server, Proxmox `apt update`), then reloads.
    private func checkForUpdates() {
        isChecking = true
        Task {
            defer { isChecking = false }
            await model.refreshCatalogs()
            await model.load()
        }
    }

    private func serverName(_ item: UpdateItem) -> String {
        model.source(for: item.serverID)?.name ?? ""
    }

    private func enqueue(_ item: UpdateItem) {
        guard let source = model.source(for: item.serverID) else { return }
        let backend = source.backend
        center.enqueue(serverID: item.serverID, serverName: source.name, kind: item.operationKind, title: item.operationTitle) { progress in
            switch item.kind {
            case .package(let id): try await backend.installPackageUpdate(id, progress: progress)
            case .system: try await backend.installSystemUpdate(progress: progress)
            }
        }
    }

    /// One confirmation, one Face ID. Sequential per NAS, parallel across NAS (OperationCenter).
    private func startBulk() {
        let items = selectedItems
        let serverCount = Set(items.map(\.serverID)).count
        Task {
            let reason = String(localized: "Update \(items.count) packages on \(serverCount) NAS")
            // Cancelled Face ID: the sheet stays open, nothing was started.
            guard await center.authorize(reason) else { return }
            showsBulkConfirmation = false
            for item in items { enqueue(item) }
            selection = []
            withAnimation { editMode = .inactive }
        }
    }

    private func startSystemUpdate(_ item: UpdateItem) {
        let name = serverName(item)
        Task {
            guard await center.authorize(String(localized: "Install DSM update and restart “\(name)”")) else {
                authorizationFailed = true
                return
            }
            enqueue(item)
        }
    }
}

/// The single confirmation of a bulk update, grouped by NAS.
struct BulkUpdateSheet: View {
    struct Group: Identifiable {
        let id: ServerID
        let name: String
        let iconName: String
        let colorName: String
        let items: [UpdateItem]
    }

    let groups: [Group]
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var total: Int { groups.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Packages are updated one after another on each NAS; different NAS update at the same time. Each package is briefly unavailable while it updates.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.availableVersion)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            ServerIcon(systemName: group.iconName, colorName: group.colorName, size: 20)
                            Text(group.name)
                            Spacer()
                            Text("^[\(group.items.count) update](inflect: true)")
                        }
                    }
                }
            }
            .navigationTitle(Text("Update ^[\(total) package](inflect: true)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm()
                } label: {
                    Text(groups.count == 1 ? "Update \(total) on “\(groups[0].name)”" : "Update \(total) on \(groups.count) NAS")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
        .presentationSizing(.form)
    }
}

struct UpdateRow<Accessory: View>: View {
    let item: UpdateItem
    var operation: OperationCenter.Operation?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(item.isSystemUpdate ? "gearshape.2.fill" : "shippingbox.fill",
                      color: item.isSystemUpdate ? .orange : Palette.stableColor(for: item.name), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium))
                Group {
                    if let installed = item.installedVersion {
                        Text("\(installed) → \(item.availableVersion)")
                    } else {
                        Text(item.availableVersion)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if item.requiresReboot {
                    Label("Restarts the NAS", systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let operation, case .running(let progress) = operation.status {
                    if let progress {
                        ProgressView(value: progress)
                    } else if item.isSystemUpdate {
                        Text("Installing. The NAS restarts and the app reconnects automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                OperationErrorText(operation)
            }
            Spacer(minLength: 0)
            if let operation, !operation.status.isFinished {
                OperationStatusView(operation)
            } else {
                accessory
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    NavigationStack {
        UpdatesView(sources: DemoData.servers.map {
            UpdateSource(id: $0.profile.id, name: $0.profile.name, iconName: $0.profile.iconName, colorName: $0.profile.colorName, backend: MockBackend(spec: $0, latency: .milliseconds(300), startConnected: true))
        })
    }
    .environment(OperationCenter())
}
