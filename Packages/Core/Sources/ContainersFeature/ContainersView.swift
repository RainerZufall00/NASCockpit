import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

@MainActor
@Observable
public final class ContainersViewModel {
    public private(set) var containers: [ContainerItem] = []
    public private(set) var projects: [ComposeProject] = []
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

    public var filteredContainers: [ContainerItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return containers }
        return containers.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.image?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public var filteredProjects: [ComposeProject] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public var runningCount: Int { containers.filter(\.status.isRunning).count }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let containers = backend.containers()
            async let projects = try? backend.composeProjects()
            self.containers = try await containers
            self.projects = await projects ?? []
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        denied = await backend.deniedActions()
    }
}

/// A write action waiting for confirmation.
enum PendingContainerAction: Identifiable {
    case container(ContainerAction, ContainerItem)
    case project(ProjectAction, ComposeProject)

    var id: String {
        switch self {
        case .container(let action, let item): "c/\(action.rawValue)/\(item.name)"
        case .project(let action, let project): "p/\(action.rawValue)/\(project.id)"
        }
    }

    /// The row the confirmation belongs to.
    var rowKey: String {
        switch self {
        case .container(_, let item): "c/\(item.name)"
        case .project(_, let project): "p/\(project.id)"
        }
    }

    var kind: OperationCenter.Kind {
        switch self {
        case .container(let action, let item): .container(action, name: item.name)
        case .project(let action, let project): .project(action, id: project.id)
        }
    }

    var title: String {
        switch self {
        case .container(.start, let item): String(localized: "Start \(item.name)")
        case .container(.stop, let item): String(localized: "Stop \(item.name)")
        case .container(.restart, let item): String(localized: "Restart \(item.name)")
        case .project(.start, let project): String(localized: "Start project \(project.name)")
        case .project(.stop, let project): String(localized: "Stop project \(project.name)")
        case .project(.rebuild, let project): String(localized: "Rebuild project \(project.name)")
        }
    }

    var confirmTitle: String {
        switch self {
        case .container(.start, _), .project(.start, _): String(localized: "Start")
        case .container(.stop, _), .project(.stop, _): String(localized: "Stop")
        case .container(.restart, _): String(localized: "Restart")
        case .project(.rebuild, _): String(localized: "Rebuild")
        }
    }

    var isDisruptive: Bool {
        switch self {
        case .container(.start, _), .project(.start, _): false
        default: true
        }
    }

    func message(serverName: String) -> String {
        switch self {
        case .container(.start, let item):
            String(localized: "The container “\(item.name)” will be started on “\(serverName)”.")
        case .container(.stop, let item):
            String(localized: "The container “\(item.name)” will be stopped on “\(serverName)”.")
        case .container(.restart, let item):
            String(localized: "The container “\(item.name)” will be restarted on “\(serverName)”. It is briefly unavailable.")
        case .project(.start, let project):
            String(localized: "All \(project.containerNames.count) containers of “\(project.name)” will be started on “\(serverName)”.")
        case .project(.stop, let project):
            String(localized: "All \(project.containerNames.count) containers of “\(project.name)” will be stopped on “\(serverName)”.")
        case .project(.rebuild, let project):
            String(localized: "The containers of “\(project.name)” on “\(serverName)” will be recreated from its compose file. Data in volumes is kept; changes made inside the containers are lost.")
        }
    }
}

public struct ContainersView: View {
    @State private var model: ContainersViewModel
    @State private var pending: PendingContainerAction?
    @Environment(OperationCenter.self) private var center

    public init(backend: any ServerBackend, serverName: String) {
        _model = State(initialValue: ContainersViewModel(backend: backend, serverName: serverName))
    }

    public var body: some View {
        List {
            if !model.filteredProjects.isEmpty {
                Section("Projects") {
                    ForEach(model.filteredProjects) { projectRow($0) }
                }
            }
            if !model.filteredContainers.isEmpty {
                Section {
                    ForEach(model.filteredContainers) { containerRow($0) }
                } header: {
                    Text("Containers")
                } footer: {
                    Text("\(model.runningCount) of \(model.containers.count) running")
                }
            }
        }
        .overlay {
            if model.containers.isEmpty && model.projects.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Containers unavailable", systemImage: "shippingbox.and.arrow.backward", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No containers", systemImage: "cube.transparent")
                }
            } else if model.filteredContainers.isEmpty && model.filteredProjects.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .searchable(text: $model.searchText, prompt: Text("Search containers"))
        .navigationTitle("Containers")
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    /// Anchored to the row, so iPad shows the popover next to it (and it survives the swipe closing).
    private func confirmation(_ row: some View, key: String) -> some View {
        row.confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending?.rowKey == key }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: action.isDisruptive ? .destructive : nil) { run(action) }
        } message: { action in
            Text(action.message(serverName: model.serverName))
        }
    }

    // MARK: Rows

    private func containerRow(_ item: ContainerItem) -> some View {
        let kinds = ContainerAction.allCases.map { OperationCenter.Kind.container($0, name: item.name) }
        let busy = kinds.contains { center.isBusy($0, on: model.serverID) }
        let operation = kinds.compactMap { center.visible($0, on: model.serverID) }.max { $0.createdAt < $1.createdAt }
        let allowed = !model.denied.contains(.containerControl)
        let row = NavigationLink {
            ContainerLogsView(backend: model.backend, container: item)
        } label: {
            ContainerRow(item: item, operation: operation)
        }
        .swipeActions(edge: .trailing) {
            if allowed, !busy { containerButtons(item) }
        }
        .contextMenu {
            if allowed, !busy { containerButtons(item) }
        }
        return confirmation(row, key: "c/\(item.name)")
    }

    @ViewBuilder
    private func containerButtons(_ item: ContainerItem) -> some View {
        if item.status.isRunning {
            Button("Stop", systemImage: "stop.circle") { pending = .container(.stop, item) }
                .tint(.orange)
            Button("Restart", systemImage: "arrow.clockwise") { pending = .container(.restart, item) }
                .tint(.blue)
        } else {
            Button("Start", systemImage: "play.circle") { pending = .container(.start, item) }
                .tint(.green)
        }
    }

    private func projectRow(_ project: ComposeProject) -> some View {
        let kinds = ProjectAction.allCases.map { OperationCenter.Kind.project($0, id: project.id) }
        let busy = kinds.contains { center.isBusy($0, on: model.serverID) }
        let operation = kinds.compactMap { center.visible($0, on: model.serverID) }.max { $0.createdAt < $1.createdAt }
        let allowed = !model.denied.contains(.projectControl)
        let row = ProjectRow(project: project, operation: operation)
            .swipeActions(edge: .trailing) {
                if allowed, !busy { projectButtons(project) }
            }
            .contextMenu {
                if allowed, !busy { projectButtons(project) }
            }
        return confirmation(row, key: "p/\(project.id)")
    }

    @ViewBuilder
    private func projectButtons(_ project: ComposeProject) -> some View {
        if project.status != .running {
            Button("Start", systemImage: "play.circle") { pending = .project(.start, project) }
                .tint(.green)
        }
        if project.status != .stopped {
            Button("Stop", systemImage: "stop.circle") { pending = .project(.stop, project) }
                .tint(.orange)
        }
        Button("Rebuild", systemImage: "hammer") { pending = .project(.rebuild, project) }
            .tint(.purple)
    }

    private func run(_ action: PendingContainerAction) {
        let backend = model.backend
        center.enqueue(serverID: model.serverID, serverName: model.serverName, kind: action.kind, title: action.title) { _ in
            switch action {
            case .container(let containerAction, let item):
                try await backend.perform(containerAction, container: item.name)
            case .project(let projectAction, let project):
                try await backend.perform(projectAction, project: project.id)
            }
        }
    }
}

struct ContainerRow: View {
    let item: ContainerItem
    var operation: OperationCenter.Operation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge("cube.fill", color: item.hasFailed ? .red : item.status.isRunning ? .green : .gray, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium))
                if let image = item.image {
                    Text(image)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    if let cpu = item.cpuPercent {
                        Label(cpu.formatted(.number.precision(.fractionLength(1))) + " %", systemImage: "cpu")
                    }
                    if let memory = item.memoryBytes {
                        Label(Format.memory(memory), systemImage: "memorychip")
                    }
                    if item.status.isRunning, let started = item.startedAt {
                        Text("started \(started, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                OperationErrorText(operation)
            }
            Spacer(minLength: 0)
            if let operation, !operation.status.isFinished {
                OperationStatusView(operation)
            } else {
                ContainerStatusChip(item: item)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectRow: View {
    let project: ComposeProject
    var operation: OperationCenter.Operation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge("square.stack.3d.up.fill", color: .purple, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.body.weight(.medium))
                Text(project.containerNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                OperationErrorText(operation)
            }
            Spacer(minLength: 0)
            if let operation, !operation.status.isFinished {
                OperationStatusView(operation)
            } else {
                Chip(title: projectTitle, color: projectColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var projectTitle: LocalizedStringKey {
        switch project.status {
        case .running: "Running"
        case .stopped: "Stopped"
        case .partial: "Partly running"
        case .unknown: "Unknown"
        }
    }

    private var projectColor: Color {
        switch project.status {
        case .running: .green
        case .stopped, .unknown: .secondary
        case .partial: .orange
        }
    }
}

struct ContainerStatusChip: View {
    let item: ContainerItem

    var body: some View {
        if item.hasFailed, let code = item.exitCode {
            Chip(title: "Exited (\(code))", color: .red)
        } else {
            Chip(title: title, color: color)
        }
    }

    private var title: LocalizedStringKey {
        switch item.status {
        case .running: "Running"
        case .restarting: "Restarting"
        case .paused: "Paused"
        case .stopped, .exited: "Stopped"
        case .created: "Created"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch item.status {
        case .running: .green
        case .restarting, .paused: .orange
        default: .secondary
        }
    }
}

struct Chip: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }
}

#Preview {
    NavigationStack {
        ContainersView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
    .environment(OperationCenter())
}
