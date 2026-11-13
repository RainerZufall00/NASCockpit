import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

// Snapshots of one Proxmox VM or container: list, take, roll back, delete.

@MainActor
@Observable
final class GuestSnapshotsModel {
    private(set) var snapshots: [GuestSnapshot] = []
    private(set) var error: BackendError?
    private(set) var isLoading = false
    private(set) var canWrite = true

    @ObservationIgnored let backend: any ServerBackend
    let guest: VirtualGuest
    let serverName: String

    init(backend: any ServerBackend, guest: VirtualGuest, serverName: String) {
        self.backend = backend
        self.guest = guest
        self.serverName = serverName
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots = try await backend.snapshots(of: guest)
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        canWrite = !(await backend.deniedActions()).contains(.guestSnapshot)
    }
}

/// A rollback or delete waiting for confirmation.
struct PendingSnapshotAction: Identifiable, Equatable {
    let action: GuestSnapshotAction
    let snapshot: GuestSnapshot
    var id: String { "\(action.rawValue)/\(snapshot.name)" }
}

struct GuestSnapshotsView: View {
    @State private var model: GuestSnapshotsModel
    @State private var pending: PendingSnapshotAction?
    @State private var showsCreate = false
    @State private var authorizationFailed = false
    @Environment(OperationCenter.self) private var center

    init(backend: any ServerBackend, guest: VirtualGuest, serverName: String) {
        _model = State(initialValue: GuestSnapshotsModel(backend: backend, guest: guest, serverName: serverName))
    }

    private var guest: VirtualGuest { model.guest }

    /// Snapshot operations of this guest, newest last.
    private var operations: [OperationCenter.Operation] {
        center.operations.filter {
            if case .guestSnapshot(_, let id, _) = $0.kind { return id == guest.id && $0.serverID == model.backend.serverID }
            return false
        }
    }

    private var running: [OperationCenter.Operation] { operations.filter { !$0.status.isFinished } }
    private var isBusy: Bool { !running.isEmpty }

    /// The last finished operation, when it failed.
    private var lastFailure: (title: String, error: BackendError)? {
        guard let last = operations.last(where: \.status.isFinished), case .failed(let error) = last.status else { return nil }
        return (last.title, error)
    }

    var body: some View {
        List {
            if !running.isEmpty {
                Section {
                    ForEach(running) { operation in
                        HStack {
                            Text(operation.title)
                            Spacer()
                            OperationStatusView(operation)
                        }
                    }
                }
            }
            if let failure = lastFailure {
                Section {
                    Label {
                        Text(failure.error.localizedDescription).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                } header: {
                    Text(verbatim: failure.title)
                }
            }
            if !model.snapshots.isEmpty {
                Section {
                    ForEach(model.snapshots) { snapshot in
                        SnapshotRow(snapshot: snapshot)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { rowActions(snapshot) }
                            .contextMenu { rowActions(snapshot) }
                    }
                } header: {
                    Text("Snapshots")
                } footer: {
                    Text(guest.kind == .virtualMachine
                         ? "Rolling back discards everything changed since the snapshot. Snapshots with RAM resume the running VM; without RAM the VM is stopped afterwards."
                         : "Rolling back discards everything changed since the snapshot. The container is stopped afterwards.")
                }
            }
        }
        .overlay {
            if model.snapshots.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Snapshots unavailable", systemImage: "camera.badge.ellipsis", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else if running.isEmpty {
                    ContentUnavailableView {
                        Label("No snapshots", systemImage: "camera.on.rectangle")
                    } description: {
                        Text("Take a snapshot before an update or a risky change. It needs storage that supports snapshots, like ZFS, LVM-thin, Ceph or qcow2.")
                    } actions: {
                        if model.canWrite {
                            Button("Take Snapshot") { showsCreate = true }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Snapshots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Take Snapshot", systemImage: "plus") { showsCreate = true }
                        .disabled(isBusy)
                }
            }
        }
        .sheet(isPresented: $showsCreate) {
            CreateSnapshotSheet(guest: guest, existing: Set(model.snapshots.map(\.name))) { name, description, memory in
                enqueue(.create, name: name, title: String(localized: "Take snapshot “\(name)”")) { backend, progress in
                    try await backend.createSnapshot(of: guest, name: name, description: description, includeMemory: memory, progress: progress)
                }
            }
        }
        .confirmationDialog(
            pending.map(dialogTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { item in
            Button(item.action == .rollback ? "Roll Back" : "Delete Snapshot", role: .destructive) { confirm(item) }
        } message: { item in
            Text(dialogMessage(item))
        }
        .alert("Not confirmed", isPresented: $authorizationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was changed.")
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    @ViewBuilder
    private func rowActions(_ snapshot: GuestSnapshot) -> some View {
        if model.canWrite, !isBusy {
            Button("Delete", systemImage: "trash") { ask(.delete, snapshot) }
                .tint(.red)
            Button("Roll Back", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") { ask(.rollback, snapshot) }
                .tint(.orange)
        }
    }

    /// Swipe actions close their row first; a dialog opened in the same moment would be dropped.
    private func ask(_ action: GuestSnapshotAction, _ snapshot: GuestSnapshot) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            pending = PendingSnapshotAction(action: action, snapshot: snapshot)
        }
    }

    private func dialogTitle(_ item: PendingSnapshotAction) -> String {
        item.action == .rollback
            ? String(localized: "Roll back “\(guest.name)” to “\(item.snapshot.name)”?")
            : String(localized: "Delete snapshot “\(item.snapshot.name)”?")
    }

    private func dialogMessage(_ item: PendingSnapshotAction) -> String {
        switch item.action {
        case .rollback:
            let after = item.snapshot.includesMemory
                ? String(localized: "The VM continues from the saved RAM state.")
                : String(localized: "The guest is stopped afterwards; start it again when you are ready.")
            return String(localized: "Everything changed in “\(guest.name)” since \(dateText(item.snapshot)) is lost. This cannot be undone.") + " " + after
        case .delete, .create:
            return String(localized: "The snapshot is removed from “\(model.serverName)”. The guest itself keeps running unchanged.")
        }
    }

    private func dateText(_ snapshot: GuestSnapshot) -> String {
        snapshot.date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "the snapshot")
    }

    /// Roll back and delete cannot be undone: Face ID or passcode first.
    private func confirm(_ item: PendingSnapshotAction) {
        let name = item.snapshot.name
        Task {
            let reason = item.action == .rollback
                ? String(localized: "Roll back “\(guest.name)” to “\(name)”")
                : String(localized: "Delete snapshot “\(name)”")
            guard await center.authorize(reason) else {
                authorizationFailed = true
                return
            }
            if item.action == .rollback {
                enqueue(.rollback, name: name, title: String(localized: "Roll back to “\(name)”")) { backend, progress in
                    try await backend.rollback(guest, to: name, progress: progress)
                }
            } else {
                enqueue(.delete, name: name, title: String(localized: "Delete snapshot “\(name)”")) { backend, progress in
                    try await backend.deleteSnapshot(name, of: guest, progress: progress)
                }
            }
        }
    }

    private func enqueue(_ action: GuestSnapshotAction, name: String, title: String,
                         work: @escaping @Sendable (any ServerBackend, @escaping ProgressHandler) async throws -> Void) {
        let backend = model.backend
        center.enqueue(serverID: backend.serverID, serverName: model.serverName,
                       kind: .guestSnapshot(action, guestID: guest.id, name: name), title: title) { progress in
            try await work(backend, progress)
        }
    }
}

struct SnapshotRow: View {
    let snapshot: GuestSnapshot

    var body: some View {
        HStack(spacing: 12) {
            IconBadge("camera.fill", color: .teal, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: snapshot.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if snapshot.includesMemory {
                        StatusChip("RAM", color: .purple).fixedSize()
                    }
                }
                if !snapshot.description.isEmpty {
                    Text(verbatim: snapshot.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let date = snapshot.date {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct CreateSnapshotSheet: View {
    let guest: VirtualGuest
    let existing: Set<String>
    let create: (_ name: String, _ description: String, _ includeMemory: Bool) -> Void

    @State private var name = GuestSnapshotName.suggested()
    @State private var description = ""
    @State private var includeMemory = false
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var problem: LocalizedStringKey? {
        if !GuestSnapshotName.isValid(trimmed) { return "Start with a letter; use letters, digits, “_” and “-” only (2 to 40 characters)." }
        if existing.contains(trimmed) { return "A snapshot with this name already exists." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Proxmox uses the name as an ID; it cannot be changed later.")
                    }
                }
                if guest.kind == .virtualMachine, guest.status.isRunning {
                    Section {
                        Toggle("Include RAM", isOn: $includeMemory)
                    } footer: {
                        Text("Saves the running state, so a rollback continues exactly there. Takes longer and needs as much space as the VM's RAM.")
                    }
                }
                Section {
                    Label {
                        Text("The guest keeps running while the snapshot is taken.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Take Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Take") {
                        create(trimmed, description.trimmingCharacters(in: .whitespacesAndNewlines), includeMemory)
                        dismiss()
                    }
                    .disabled(problem != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    NavigationStack {
        GuestSnapshotsView(
            backend: MockBackend.preview(DemoData.proxmoxID),
            guest: VirtualGuest(id: "qemu/100", vmid: 100, name: "homeassistant", node: "pve", kind: .virtualMachine, status: .running),
            serverName: "Proxmox Lab"
        )
    }
    .environment(OperationCenter())
}
