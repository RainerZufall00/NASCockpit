import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

@MainActor
@Observable
public final class PackagesViewModel {
    public private(set) var packages: [PackageItem] = []
    public private(set) var isLoading = false
    public private(set) var error: BackendError?
    /// Actions DSM rejected with "no permission"; hidden for this NAS.
    public private(set) var denied: Set<WriteAction> = []
    public var searchText = ""

    @ObservationIgnored let backend: any ServerBackend
    public let serverName: String

    public init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    public var serverID: ServerID { backend.serverID }

    public var filtered: [PackageItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public var withUpdates: [PackageItem] { filtered.filter(\.hasUpdate) }
    public var upToDate: [PackageItem] { filtered.filter { !$0.hasUpdate } }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            packages = try await backend.installedPackages()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        denied = await backend.deniedActions()
    }

    func canUpdate(_ package: PackageItem) -> Bool {
        package.hasUpdate && !denied.contains(.packageUpdate)
    }

    func canControl(_ package: PackageItem) -> Bool {
        !denied.contains(.packageControl) && (package.status == .running || package.status == .stopped)
    }
}

/// A write action waiting for confirmation. The dialog names the action and the NAS.
enum PackageAction: Identifiable {
    case update(PackageItem)
    case start(PackageItem)
    case stop(PackageItem)

    var id: String {
        switch self {
        case .update(let package): "update/\(package.id)"
        case .start(let package): "start/\(package.id)"
        case .stop(let package): "stop/\(package.id)"
        }
    }

    var package: PackageItem {
        switch self {
        case .update(let package), .start(let package), .stop(let package): package
        }
    }

    var kind: OperationCenter.Kind {
        switch self {
        case .update(let package): .packageUpdate(packageID: package.id)
        case .start(let package): .packageStart(packageID: package.id)
        case .stop(let package): .packageStop(packageID: package.id)
        }
    }

    var title: String {
        switch self {
        case .update(let package): String(localized: "Update \(package.name)")
        case .start(let package): String(localized: "Start \(package.name)")
        case .stop(let package): String(localized: "Stop \(package.name)")
        }
    }

    func message(serverName: String) -> String {
        switch self {
        case .update(let package):
            String(localized: "\(package.name) on “\(serverName)” will be updated from \(package.version) to \(package.availableVersion ?? ""). The package is unavailable while it updates.")
        case .start(let package):
            String(localized: "\(package.name) will be started on “\(serverName)”.")
        case .stop(let package):
            String(localized: "\(package.name) will be stopped on “\(serverName)”. Services that depend on it stop working until it is started again.")
        }
    }
}

public struct PackagesView: View {
    @State private var model: PackagesViewModel
    @State private var pending: PackageAction?
    @Environment(OperationCenter.self) private var center

    public init(backend: any ServerBackend, serverName: String) {
        _model = State(initialValue: PackagesViewModel(backend: backend, serverName: serverName))
    }

    public var body: some View {
        List {
            if !model.withUpdates.isEmpty {
                Section("Updates Available") {
                    ForEach(model.withUpdates) { row($0) }
                }
            }
            if !model.upToDate.isEmpty {
                Section("Installed") {
                    ForEach(model.upToDate) { row($0) }
                }
            }
        }
        .overlay {
            if model.packages.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Packages unavailable", systemImage: "shippingbox", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No packages", systemImage: "shippingbox")
                }
            } else if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .searchable(text: $model.searchText, prompt: Text("Search packages"))
        .navigationTitle("Packages")
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    private func row(_ package: PackageItem) -> some View {
        let busy = isBusy(package)
        let operation = latestOperation(for: package)
        return PackageRow(package: package, operation: operation)
            // Anchored to the row so iPad shows the popover next to it.
            .confirmationDialog(
                pending?.title ?? "",
                isPresented: Binding(get: { pending?.package.id == package.id }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { action in
                Button(confirmTitle(action), role: isStop(action) ? .destructive : nil) { run(action) }
            } message: { action in
                Text(action.message(serverName: model.serverName))
            }
            .swipeActions(edge: .trailing) {
                if !busy, model.canUpdate(package) {
                    Button("Update", systemImage: "arrow.down.circle") { pending = .update(package) }
                        .tint(.blue)
                }
                if !busy, model.canControl(package) {
                    controlButton(package)
                }
            }
            .contextMenu {
                if !busy, model.canUpdate(package) {
                    Button("Update", systemImage: "arrow.down.circle") { pending = .update(package) }
                }
                if !busy, model.canControl(package) {
                    controlButton(package)
                }
            }
    }

    @ViewBuilder
    private func controlButton(_ package: PackageItem) -> some View {
        if package.status == .running {
            Button("Stop", systemImage: "stop.circle") { pending = .stop(package) }
                .tint(.orange)
        } else {
            Button("Start", systemImage: "play.circle") { pending = .start(package) }
                .tint(.green)
        }
    }

    private func kinds(_ package: PackageItem) -> [OperationCenter.Kind] {
        [.packageUpdate(packageID: package.id), .packageStart(packageID: package.id), .packageStop(packageID: package.id)]
    }

    private func isBusy(_ package: PackageItem) -> Bool {
        kinds(package).contains { center.isBusy($0, on: model.serverID) }
    }

    private func latestOperation(for package: PackageItem) -> OperationCenter.Operation? {
        kinds(package)
            .compactMap { center.visible($0, on: model.serverID) }
            .max { $0.createdAt < $1.createdAt }
    }

    private func isStop(_ action: PackageAction) -> Bool {
        if case .stop = action { return true }
        return false
    }

    private func confirmTitle(_ action: PackageAction) -> String {
        switch action {
        case .update: String(localized: "Update on “\(model.serverName)”")
        case .start: String(localized: "Start")
        case .stop: String(localized: "Stop")
        }
    }

    private func run(_ action: PackageAction) {
        let backend = model.backend
        let package = action.package
        center.enqueue(serverID: model.serverID, serverName: model.serverName, kind: action.kind, title: action.title) { progress in
            switch action {
            case .update: try await backend.installPackageUpdate(package.id, progress: progress)
            case .start: try await backend.setPackage(package.id, running: true)
            case .stop: try await backend.setPackage(package.id, running: false)
            }
        }
    }
}

struct PackageRow: View {
    let package: PackageItem
    var operation: OperationCenter.Operation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge("shippingbox.fill", color: Palette.stableColor(for: package.id), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.name).font(.body.weight(.medium))
                if let available = package.availableVersion {
                    Text("\(package.version) → \(available)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                } else {
                    Text(package.version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let summary = package.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let operation {
                    if case .running(let progress?) = operation.status {
                        ProgressView(value: progress)
                    }
                    OperationErrorText(operation)
                }
            }
            Spacer(minLength: 0)
            if let operation, !operation.status.isFinished {
                OperationStatusView(operation)
            } else {
                StatusChip(status: package.status)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct StatusChip: View {
    let status: PackageStatus

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var title: LocalizedStringKey {
        switch status {
        case .running: "Running"
        case .stopped: "Stopped"
        case .transitioning: "Working…"
        case .broken: "Needs repair"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .stopped: .secondary
        case .transitioning: .orange
        case .broken: .red
        case .unknown: .secondary
        }
    }
}

#Preview {
    NavigationStack {
        PackagesView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
    .environment(OperationCenter())
}
