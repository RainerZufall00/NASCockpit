import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend
import LogsFeature

// MARK: Presentation helpers

extension BackupDestination {
    var title: String {
        switch self {
        case .local: String(localized: "Local or USB drive")
        case .remoteNAS: String(localized: "Remote NAS")
        case .cloud(let name): name ?? String(localized: "Cloud")
        case .other(let raw): raw.isEmpty ? String(localized: "Unknown destination") : raw
        }
    }

    var symbol: String {
        switch self {
        case .local: "externaldrive.fill"
        case .remoteNAS: "server.rack"
        case .cloud: "icloud.fill"
        case .other: "archivebox.fill"
        }
    }
}

extension BackupTask {
    /// Short status for chips: what is happening now, else how the last run ended.
    var statusTitle: String {
        switch activity {
        case .running(let progress):
            progress.map { String(localized: "Running \(Int(($0 * 100).rounded())) %") } ?? String(localized: "Running")
        case .waiting: String(localized: "Waiting")
        case .maintenance: String(localized: "Checking")
        case .suspended: String(localized: "Suspended")
        case .idle where isTargetOffline: String(localized: "Destination offline")
        case .idle:
            switch lastResult {
            case .success: String(localized: "Successful")
            case .partial: String(localized: "Partial")
            case .failed: String(localized: "Failed")
            case .cancelled: String(localized: "Cancelled")
            case nil: lastBackup == nil ? String(localized: "Never run") : String(localized: "Unknown")
            }
        }
    }

    var statusColor: Color {
        switch activity {
        case .running: .blue
        case .waiting, .maintenance: .teal
        case .suspended: .orange
        case .idle where isTargetOffline: .red
        case .idle:
            switch lastResult {
            case .success: .green
            case .partial: .orange
            case .failed: .red
            case .cancelled, nil: .gray
            }
        }
    }

    var progress: Double? {
        if case .running(let progress) = activity { return progress }
        return nil
    }
}

/// Which backup software the screen talks about. Only the wording differs.
public enum BackupProduct: Sendable {
    case hyperBackup
    /// Proxmox vzdump jobs (Datacenter → Backup).
    case proxmox

    var title: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Hyper Backup"
        case .proxmox: "Backups"
        }
    }

    var unavailableTitle: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Hyper Backup unavailable"
        case .proxmox: "Backups unavailable"
        }
    }

    var emptyHint: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Create backup tasks in Hyper Backup on the NAS."
        case .proxmox: "Create backup jobs under Datacenter → Backup on the host."
        }
    }

    var listFooter: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Backups run on the NAS. The app only starts or cancels them; you can close it in the meantime."
        case .proxmox: "Backups run on the host. The app only starts or cancels them; you can close it in the meantime. The last result comes from the host's task history."
        }
    }

    var startHint: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Hyper Backup starts the task right away, outside its schedule."
        case .proxmox: "The job runs right away with its own settings, outside its schedule."
        }
    }

    func startMessage(serverName: String, task: BackupTask) -> String {
        switch self {
        case .hyperBackup: String(localized: "Hyper Backup on “\(serverName)” starts “\(task.name)” to \(task.destination.title).")
        case .proxmox: String(localized: "“\(serverName)” backs up “\(task.name)” to \(task.destination.title) now.")
        }
    }

    var logTitle: LocalizedStringKey {
        switch self {
        case .hyperBackup: "Hyper Backup"
        case .proxmox: "Backup tasks"
        }
    }
}

// MARK: Model

@MainActor
@Observable
final class BackupModel {
    private(set) var tasks: [BackupTask] = []
    private(set) var error: BackendError?
    private(set) var isLoading = false
    private(set) var canControl = true
    /// A start or cancel from this screen that failed; shown as an alert.
    var failure: Failure?
    /// The task detail page is on screen; it shows the alert instead of the list.
    var isShowingDetail = false
    @ObservationIgnored private var watched: Set<UUID> = []

    struct Failure: Identifiable {
        let id: UUID
        let title: String
        let message: String
    }

    @ObservationIgnored let backend: any ServerBackend
    let serverName: String
    /// The NAS offers Hyper Backup's log.
    let showsLogs: Bool
    let product: BackupProduct

    init(backend: any ServerBackend, serverName: String, showsLogs: Bool, product: BackupProduct) {
        self.backend = backend
        self.serverName = serverName
        self.showsLogs = showsLogs
        self.product = product
    }

    func task(_ id: String) -> BackupTask? { tasks.first { $0.id == id } }

    func watch(_ operation: UUID) { watched.insert(operation) }

    /// Turns a finished, failed operation started here into an alert.
    func collectFailures(from center: OperationCenter) {
        for operation in center.operations where watched.contains(operation.id) && operation.status.isFinished {
            watched.remove(operation.id)
            if case .failed(let error) = operation.status, error != .cancelled {
                failure = Failure(id: operation.id, title: operation.title, message: error.localizedDescription)
            }
        }
    }

    var isAnyBusy: Bool { tasks.contains { $0.activity.isBusy } }
    var successCount: Int { tasks.filter { !$0.activity.isBusy && $0.lastResult == .success }.count }
    var attentionCount: Int { tasks.filter { !$0.activity.isBusy && ($0.needsAttention || $0.isTargetOffline) }.count }
    var runningCount: Int { tasks.filter { $0.activity.isBusy }.count }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await backend.backupTasks()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        canControl = !(await backend.deniedActions()).contains(.backupControl)
    }

    /// Refreshes while a backup runs, so the progress moves.
    func pollWhileBusy() async {
        while isAnyBusy, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

/// A start / cancel waiting for confirmation.
struct PendingBackup: Identifiable, Equatable {
    let task: BackupTask
    let control: BackupControl
    var id: String { "\(task.id)/\(control.rawValue)" }
}

// MARK: List

public struct BackupView: View {
    @State private var model: BackupModel
    @State private var pending: PendingBackup?
    @Environment(OperationCenter.self) private var center

    public init(backend: any ServerBackend, serverName: String, showsLogs: Bool = true, product: BackupProduct = .hyperBackup) {
        _model = State(initialValue: BackupModel(backend: backend, serverName: serverName, showsLogs: showsLogs, product: product))
    }

    public var body: some View {
        List {
            if !model.tasks.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        StatTile(value: model.successCount, title: "Successful", systemImage: "checkmark.circle.fill", color: .green)
                        StatTile(value: model.attentionCount, title: "Attention", systemImage: "exclamationmark.triangle.fill",
                                   color: model.attentionCount > 0 ? .red : .gray)
                        StatTile(value: model.runningCount, title: "Running", systemImage: "arrow.triangle.2.circlepath",
                                   color: model.runningCount > 0 ? .blue : .gray)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(model.tasks) { task in
                        NavigationLink {
                            BackupTaskDetailView(model: model, taskID: task.id)
                        } label: {
                            BackupRow(task: task, operation: operation(for: task))
                        }
                        .backupConfirmation(for: $pending, task: task, serverName: model.serverName, product: model.product, run: run)
                        .swipeActions { actionButton(task) }
                        .contextMenu { actionButton(task) }
                    }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text(model.product.listFooter)
                }
                if model.showsLogs {
                    Section {
                        NavigationLink {
                            LogsView(backend: model.backend, sources: [.backup], backupTitle: model.product.logTitle)
                        } label: {
                            BadgeLabel("Log", systemImage: "list.bullet.rectangle.fill", color: .gray,
                                       subtitle: Text("Runs, warnings and errors of all tasks"))
                        }
                    }
                }
            }
        }
        .overlay {
            if model.tasks.isEmpty {
                if let error = model.error {
                    ContentUnavailableView(model.product.unavailableTitle, systemImage: "clock.arrow.circlepath", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No backup tasks", systemImage: "clock.arrow.circlepath",
                                           description: Text(model.product.emptyHint))
                }
            }
        }
        .navigationTitle(model.product.title)
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: model.isAnyBusy) { await model.pollWhileBusy() }
        .onChange(of: center.completedCount) {
            model.collectFailures(from: center)
            Task { await model.load() }
        }
        .backupFailureAlert(model: model, isActive: !model.isShowingDetail)
    }

    private func operation(for task: BackupTask) -> OperationCenter.Operation? {
        let id = model.backend.serverID
        return center.visible(.backup(.start, taskID: task.id), on: id) ?? center.visible(.backup(.cancel, taskID: task.id), on: id)
    }

    @ViewBuilder
    private func actionButton(_ task: BackupTask) -> some View {
        if model.canControl, operation(for: task).map({ !$0.status.isFinished }) != true {
            if task.activity.isBusy {
                Button("Cancel", systemImage: "stop.circle") { pending = PendingBackup(task: task, control: .cancel) }
                    .tint(.red)
            } else {
                Button("Back Up Now", systemImage: "play.circle") { pending = PendingBackup(task: task, control: .start) }
                    .tint(.blue)
            }
        }
    }

    private func run(_ pending: PendingBackup) {
        BackupActions.run(pending, model: model, center: center)
    }
}

enum BackupActions {
    @MainActor
    static func run(_ pending: PendingBackup, model: BackupModel, center: OperationCenter) {
        let backend = model.backend
        let control = pending.control
        let id = pending.task.id
        let title = control == .start
            ? String(localized: "Back up “\(pending.task.name)”")
            : String(localized: "Cancel backup “\(pending.task.name)”")
        let operation = center.enqueue(serverID: backend.serverID, serverName: model.serverName, kind: .backup(control, taskID: id), title: title) { _ in
            try await backend.perform(control, backup: id)
        }
        model.watch(operation)
    }
}

// MARK: Rows and tiles

struct BackupRow: View {
    let task: BackupTask
    let operation: OperationCenter.Operation?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(task.destination.symbol, color: task.statusColor, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let operation {
                        OperationStatusView(operation)
                    } else {
                        StatusChip(verbatim: task.statusTitle, color: task.statusColor)
                    }
                }
                if task.activity.isBusy {
                    ProgressView(value: task.progress ?? 0)
                        .tint(task.statusColor)
                        .opacity(task.progress == nil ? 0.4 : 1)
                }
                HStack(spacing: 4) {
                    Text(task.destination.title)
                    if let last = task.lastBackup {
                        Text("·")
                        Text(last, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if task.isTargetOffline, !task.activity.isBusy {
                    Text("The destination does not respond. Backups to it cannot run.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OperationErrorText(operation)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Detail

/// One task with a clearly visible start / cancel button.
struct BackupTaskDetailView: View {
    let model: BackupModel
    let taskID: String
    @State private var pending: PendingBackup?
    @Environment(OperationCenter.self) private var center

    var body: some View {
        if let task = model.task(taskID) {
            let id = model.backend.serverID
            let operation = center.visible(.backup(.start, taskID: task.id), on: id) ?? center.visible(.backup(.cancel, taskID: task.id), on: id)
            let sending = operation.map { !$0.status.isFinished } ?? false
            List {
                Section {
                    VStack(spacing: 10) {
                        IconBadge(task.destination.symbol, color: task.statusColor, size: 72)
                        Text(task.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        StatusChip(verbatim: task.statusTitle, color: task.statusColor)
                        if task.activity.isBusy {
                            ProgressView(value: task.progress ?? 0)
                                .tint(task.statusColor)
                                .padding(.horizontal, 40)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Destination", value: task.destination.title)
                    if let online = task.targetOnline {
                        LabeledContent("Destination status") {
                            HStack(spacing: 4) {
                                Image(systemName: online ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                Text(online ? "Online" : "Offline")
                            }
                            .foregroundStyle(online ? Color.green : Color.red)
                        }
                    }
                    LabeledContent("Last backup") {
                        if let last = task.lastBackup {
                            Text(last, format: .dateTime.day().month().hour().minute())
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Next backup") {
                        if let next = task.nextBackup {
                            Text(next, format: .dateTime.weekday().day().month().hour().minute())
                        } else {
                            Text("Not scheduled")
                        }
                    }
                    LabeledContent("NAS", value: model.serverName)
                }
                if model.showsLogs {
                    Section {
                        NavigationLink {
                            LogsView(backend: model.backend, sources: [.backup], backupTask: task.name, backupTitle: model.product.logTitle)
                        } label: {
                            Label("Show Log", systemImage: "list.bullet.rectangle")
                        }
                    }
                }
                if let operation, case .failed(let error) = operation.status {
                    Section {
                        Label {
                            Text(error.localizedDescription).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    } header: {
                        Text("Last attempt failed")
                    }
                }
                if model.canControl {
                    Section {
                        let control: BackupControl = task.activity.isBusy ? .cancel : .start
                        Button(role: control == .cancel ? .destructive : nil) {
                            pending = PendingBackup(task: task, control: control)
                        } label: {
                            HStack {
                                Label(control == .start ? "Back Up Now" : "Cancel Backup",
                                      systemImage: control == .start ? "play.circle.fill" : "stop.circle.fill")
                                Spacer()
                                if sending { ProgressView() }
                            }
                        }
                        .disabled(sending)
                        .backupConfirmation(for: $pending, task: task, serverName: model.serverName, product: model.product) { pending in
                            BackupActions.run(pending, model: model, center: center)
                        }
                    } footer: {
                        if task.activity.isBusy {
                            Text("Cancelling keeps the versions that already exist on the destination.")
                        } else if task.isTargetOffline {
                            Text("The destination is offline. Switch it on or check the connection first; the app checks it again before starting.")
                        } else {
                            Text(model.product.startHint)
                        }
                    }
                }
            }
            .navigationTitle(task.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            // The list's polling stops while this page is pushed, so poll here too.
            .task(id: model.isAnyBusy) { await model.pollWhileBusy() }
            .onChange(of: center.completedCount) {
                model.collectFailures(from: center)
                Task { await model.load() }
            }
            .onAppear { model.isShowingDetail = true }
            .onDisappear { model.isShowingDetail = false }
            .backupFailureAlert(model: model, isActive: true)
        } else {
            ContentUnavailableView("Task not found", systemImage: "clock.arrow.circlepath")
        }
    }
}

extension View {
    func backupFailureAlert(model: BackupModel, isActive: Bool) -> some View {
        alert(
            model.failure?.title ?? "",
            isPresented: Binding(get: { isActive && model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK", role: .cancel) { model.failure = nil }
        } message: { failure in
            Text(failure.message)
        }
    }

    func backupConfirmation(for pending: Binding<PendingBackup?>, task: BackupTask, serverName: String, product: BackupProduct, run: @escaping (PendingBackup) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue.map { $0.control == .start ? String(localized: "Back up “\($0.task.name)” now?") : String(localized: "Cancel “\($0.task.name)”?") } ?? "",
            isPresented: Binding(get: { pending.wrappedValue?.task.id == task.id }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { pending in
            Button(pending.control == .start ? "Back Up Now" : "Cancel Backup", role: pending.control == .cancel ? .destructive : nil) { run(pending) }
        } message: { pending in
            Text(pending.control == .start
                 ? product.startMessage(serverName: serverName, task: pending.task)
                 : String(localized: "The running backup “\(pending.task.name)” on “\(serverName)” stops. Existing versions are kept."))
        }
    }
}

#Preview {
    NavigationStack {
        BackupView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
    .environment(OperationCenter())
}
