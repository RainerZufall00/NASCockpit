import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

// MARK: Presentation helpers

extension ReplicationPlan {
    var statusTitle: String {
        if isSyncing {
            return progress.map { String(localized: "Syncing \(Int(($0 * 100).rounded())) %") } ?? String(localized: "Syncing")
        }
        switch lastSyncSucceeded {
        case true?: return String(localized: "Synced")
        case false?: return String(localized: "Failed")
        case nil: return String(localized: "Not synced yet")
        }
    }

    var statusColor: Color {
        if isSyncing { return .blue }
        switch lastSyncSucceeded {
        case true?: return .green
        case false?: return .red
        case nil: return .gray
        }
    }

    /// "photo → office-nas" or "office-nas → scans-copy".
    var directionText: String {
        let partner = partner ?? String(localized: "this NAS")
        return role == .source ? "\(name) → \(partner)" : "\(partner) → \(name)"
    }
}

extension ShareSnapshots {
    var countText: String {
        snapshots.count == 1 ? String(localized: "1 snapshot") : String(localized: "\(snapshots.count) snapshots")
    }
}

// MARK: Model

@MainActor
@Observable
final class SnapshotsModel {
    private(set) var shares: [ShareSnapshots] = []
    private(set) var plans: [ReplicationPlan] = []
    private(set) var sharesError: BackendError?
    private(set) var plansError: BackendError?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var canSnapshot = true
    private(set) var canSync = true

    @ObservationIgnored let backend: any ServerBackend
    let serverName: String
    let showsSnapshots: Bool
    let showsReplication: Bool

    init(backend: any ServerBackend, serverName: String, capabilities: Set<Capability>) {
        self.backend = backend
        self.serverName = serverName
        showsSnapshots = capabilities.contains(.snapshots)
        showsReplication = capabilities.contains(.replication)
    }

    func share(_ name: String) -> ShareSnapshots? { shares.first { $0.share == name } }
    func plan(_ id: String) -> ReplicationPlan? { plans.first { $0.id == id } }

    var snapshotCount: Int { shares.reduce(0) { $0 + $1.snapshots.count } }
    var newestSnapshot: Date? { shares.compactMap { $0.latest?.date }.max() }
    var replicationIssues: Int { plans.filter { !$0.isSyncing && $0.needsAttention }.count }
    var isAnySyncing: Bool { plans.contains(where: \.isSyncing) }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        // Each area loads on its own: one failing API must not hide the other.
        if showsSnapshots {
            do {
                shares = try await backend.shareSnapshots()
                sharesError = nil
            } catch {
                let mapped = BackendError(error)
                if mapped != .cancelled { sharesError = mapped }
            }
        }
        if showsReplication {
            do {
                plans = try await backend.replicationPlans()
                plansError = nil
            } catch {
                let mapped = BackendError(error)
                if mapped != .cancelled { plansError = mapped }
            }
        }
        let denied = await backend.deniedActions()
        canSnapshot = !denied.contains(.snapshot)
        canSync = !denied.contains(.replicationSync)
    }

    /// Only the replication plans change while a sync runs.
    func pollWhileSyncing() async {
        while isAnySyncing, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if let plans = try? await backend.replicationPlans() { self.plans = plans }
        }
    }

    func takeSnapshot(of share: String, description: String, center: OperationCenter) {
        let backend = backend
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        center.enqueue(serverID: backend.serverID, serverName: serverName, kind: .snapshot(share: share),
                       title: String(localized: "Snapshot of “\(share)”")) { _ in
            try await backend.takeSnapshot(of: share, description: text.isEmpty ? String(localized: "Taken with NAS Cockpit") : text)
        }
    }

    func sync(_ plan: ReplicationPlan, center: OperationCenter) {
        let backend = backend
        let id = plan.id
        center.enqueue(serverID: backend.serverID, serverName: serverName, kind: .replicationSync(planID: id),
                       title: String(localized: "Sync “\(plan.name)”")) { _ in
            try await backend.syncReplication(id)
        }
    }
}

// MARK: Overview

public struct SnapshotsView: View {
    @State private var model: SnapshotsModel
    @Environment(OperationCenter.self) private var center

    public init(backend: any ServerBackend, serverName: String, capabilities: Set<Capability>) {
        _model = State(initialValue: SnapshotsModel(backend: backend, serverName: serverName, capabilities: capabilities))
    }

    public var body: some View {
        List {
            if model.hasLoaded {
                Section {
                    HStack(spacing: 10) {
                        if model.showsSnapshots {
                            StatTile(value: model.snapshotCount, title: "Snapshots", systemImage: "camera.fill", color: .teal)
                            StatTile(text: newestText, title: "Newest", systemImage: "clock.fill", color: newestColor)
                        }
                        if model.showsReplication {
                            StatTile(value: model.replicationIssues, title: "Replication issues",
                                     systemImage: "exclamationmark.triangle.fill", color: model.replicationIssues > 0 ? .red : .gray)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if model.showsSnapshots {
                Section {
                    if let error = model.sharesError, model.shares.isEmpty {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if model.hasLoaded, model.shares.isEmpty {
                        Text("No shared folder supports snapshots (Btrfs volume needed).").foregroundStyle(.secondary)
                    }
                    ForEach(model.shares) { share in
                        NavigationLink {
                            ShareSnapshotsView(model: model, shareName: share.share)
                        } label: {
                            ShareSnapshotRow(share: share, operation: center.visible(.snapshot(share: share.share), on: model.backend.serverID))
                        }
                    }
                } header: {
                    Text("Shared Folders")
                } footer: {
                    Text("Take a snapshot before risky changes, e.g. an update of a container that keeps its data in the folder.")
                }
            }
            if model.showsReplication {
                Section {
                    if let error = model.plansError, model.plans.isEmpty {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if model.hasLoaded, model.plans.isEmpty {
                        Text("No replication plans").foregroundStyle(.secondary)
                    }
                    ForEach(model.plans) { plan in
                        NavigationLink {
                            ReplicationPlanView(model: model, planID: plan.id)
                        } label: {
                            ReplicationRow(plan: plan, operation: center.visible(.replicationSync(planID: plan.id), on: model.backend.serverID))
                        }
                    }
                } header: {
                    Text("Replication")
                }
            }
        }
        .overlay {
            if !model.hasLoaded { ProgressView() }
        }
        .navigationTitle("Snapshot Replication")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: model.isAnySyncing) { await model.pollWhileSyncing() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    private var newestText: Text {
        guard let date = model.newestSnapshot else { return Text("–") }
        return Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// Orange when the newest snapshot is older than two days.
    private var newestColor: Color {
        guard let date = model.newestSnapshot else { return .gray }
        return date < .now.addingTimeInterval(-2 * 86_400) ? .orange : .green
    }
}

// MARK: Rows

struct ShareSnapshotRow: View {
    let share: ShareSnapshots
    let operation: OperationCenter.Operation?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge("folder.fill", color: share.snapshots.isEmpty ? .gray : .teal, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(share.share).font(.body.weight(.medium))
                Group {
                    if let date = share.latest?.date {
                        Text("\(share.countText) · newest \(date, format: .relative(presentation: .named))")
                    } else {
                        Text("No snapshots")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let operation { OperationStatusView(operation) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ReplicationRow: View {
    let plan: ReplicationPlan
    let operation: OperationCenter.Operation?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(plan.role == .source ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill",
                      color: plan.statusColor, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(plan.directionText).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let operation {
                        OperationStatusView(operation)
                    } else {
                        StatusChip(verbatim: plan.statusTitle, color: plan.statusColor)
                    }
                }
                if plan.isSyncing {
                    ProgressView(value: plan.progress ?? 0)
                        .tint(plan.statusColor)
                        .opacity(plan.progress == nil ? 0.4 : 1)
                }
                if let last = plan.lastSync {
                    Text("Last sync \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shared folder

/// Snapshots of one shared folder with a clearly visible "Take Snapshot Now" button.
struct ShareSnapshotsView: View {
    let model: SnapshotsModel
    let shareName: String
    @State private var askDescription = false
    @State private var descriptionText = ""
    @Environment(OperationCenter.self) private var center

    var body: some View {
        if let share = model.share(shareName) {
            let operation = center.visible(.snapshot(share: share.share), on: model.backend.serverID)
            let busy = operation.map { !$0.status.isFinished } ?? false
            List {
                Section {
                    VStack(spacing: 10) {
                        IconBadge("folder.fill", color: .teal, size: 72)
                        Text(share.share).font(.title2.weight(.bold))
                        StatusChip(verbatim: share.countText, color: .teal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                if model.canSnapshot {
                    Section {
                        Button {
                            descriptionText = ""
                            askDescription = true
                        } label: {
                            HStack {
                                Label("Take Snapshot Now", systemImage: "camera.fill")
                                Spacer()
                                if busy { ProgressView() }
                            }
                        }
                        .disabled(busy)
                        if let operation, case .failed = operation.status {
                            OperationStatusView(operation)
                        }
                    } footer: {
                        Text("A snapshot takes a few seconds and uses space only for files that change afterwards. Retention may remove it later unless you lock it in DSM.")
                    }
                }
                Section("Snapshots") {
                    if share.snapshots.isEmpty {
                        Text("No snapshots yet").foregroundStyle(.secondary)
                    }
                    ForEach(share.snapshots.prefix(200)) { snapshot in
                        SnapshotRow(snapshot: snapshot)
                    }
                }
            }
            .navigationTitle(share.share)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .onChange(of: center.completedCount) { Task { await model.load() } }
            .alert("Take a snapshot of “\(share.share)”?", isPresented: $askDescription) {
                TextField("Description (optional)", text: $descriptionText)
                Button("Cancel", role: .cancel) {}
                Button("Take Snapshot") {
                    model.takeSnapshot(of: share.share, description: descriptionText, center: center)
                }
            } message: {
                Text("The snapshot is taken on “\(model.serverName)”.")
            }
        } else {
            ContentUnavailableView("Shared folder not found", systemImage: "folder")
        }
    }
}

struct SnapshotRow: View {
    let snapshot: SnapshotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let date = snapshot.date {
                    Text(date, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.body.monospacedDigit())
                } else {
                    Text(snapshot.id).font(.body.monospaced())
                }
                Spacer()
                if snapshot.isImmutable {
                    StatusChip("Immutable", color: .purple)
                } else if snapshot.isLocked {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).accessibilityLabel("Locked")
                }
            }
            HStack(spacing: 6) {
                Text(snapshot.isScheduled ? "Scheduled" : "Manual")
                if let description = snapshot.description {
                    Text("·")
                    Text(description).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Replication plan

struct ReplicationPlanView: View {
    let model: SnapshotsModel
    let planID: String
    @State private var confirmSync = false
    @Environment(OperationCenter.self) private var center

    var body: some View {
        if let plan = model.plan(planID) {
            let operation = center.visible(.replicationSync(planID: plan.id), on: model.backend.serverID)
            let sending = operation.map { !$0.status.isFinished } ?? false
            List {
                Section {
                    VStack(spacing: 10) {
                        IconBadge(plan.role == .source ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill",
                                  color: plan.statusColor, size: 72)
                        Text(plan.directionText).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                        StatusChip(verbatim: plan.statusTitle, color: plan.statusColor)
                        if plan.isSyncing {
                            ProgressView(value: plan.progress ?? 0)
                                .tint(plan.statusColor)
                                .padding(.horizontal, 40)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Role", value: plan.role == .source ? String(localized: "This NAS sends") : String(localized: "This NAS receives"))
                    LabeledContent("Partner", value: plan.partner ?? String(localized: "This NAS"))
                    LabeledContent("Last sync") {
                        if let last = plan.lastSync {
                            Text(last, format: .dateTime.day().month().hour().minute())
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Next sync") {
                        if let next = plan.nextSync {
                            Text(next, format: .dateTime.weekday().day().month().hour().minute())
                        } else {
                            Text("Not scheduled")
                        }
                    }
                    if plan.failedSyncCount > 0 {
                        LabeledContent("Failed syncs", value: String(plan.failedSyncCount))
                    }
                }
                if let operation, case .failed = operation.status {
                    Section { OperationStatusView(operation) }
                }
                if model.canSync, plan.canSync {
                    Section {
                        Button {
                            confirmSync = true
                        } label: {
                            HStack {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if sending { ProgressView() }
                            }
                        }
                        .disabled(sending || plan.isSyncing)
                        .confirmationDialog("Sync “\(plan.name)” now?", isPresented: $confirmSync, titleVisibility: .visible) {
                            Button("Sync Now") { model.sync(plan, center: center) }
                        } message: {
                            Text("“\(model.serverName)” takes a new snapshot of “\(plan.name)” and sends the changes to \(plan.partner ?? String(localized: "the replica")).")
                        }
                    } footer: {
                        Text("The sync runs on the NAS; you can close the app in the meantime.")
                    }
                } else if plan.role == .destination {
                    Section {
                        Label("This NAS receives the replica. Syncs are started on the sending NAS.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            // The overview's polling stops while this page is pushed.
            .task(id: model.isAnySyncing) { await model.pollWhileSyncing() }
            .onChange(of: center.completedCount) { Task { await model.load() } }
        } else {
            ContentUnavailableView("Plan not found", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

#Preview {
    NavigationStack {
        SnapshotsView(backend: MockBackend.preview(), serverName: "Home NAS", capabilities: [.snapshots, .replication])
    }
    .environment(OperationCenter())
}
