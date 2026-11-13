import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

@MainActor
@Observable
public final class LogsViewModel {
    public enum Timeframe: String, CaseIterable, Identifiable, Hashable {
        case lastHour, lastDay, lastWeek, all

        public var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .lastHour: "Last hour"
            case .lastDay: "Last 24 hours"
            case .lastWeek: "Last 7 days"
            case .all: "All"
            }
        }

        func startDate(now: Date = .now) -> Date? {
            switch self {
            case .lastHour: now.addingTimeInterval(-3600)
            case .lastDay: now.addingTimeInterval(-86_400)
            case .lastWeek: now.addingTimeInterval(-7 * 86_400)
            case .all: nil
            }
        }
    }

    public struct FilterKey: Hashable {
        let source: LogSource
        let search: String
        let timeframe: Timeframe
        let levels: Set<LogLevel>
    }

    public var source: LogSource
    public let sources: [LogSource]
    /// Hyper Backup: only this task's entries.
    public let backupTask: String?
    public var searchText = ""
    public var timeframe: Timeframe
    public var levels: Set<LogLevel> = Set(LogLevel.allCases)

    public private(set) var entries: [LogEntry] = []
    public private(set) var total = 0
    public private(set) var isLoading = false
    public private(set) var error: BackendError?
    public private(set) var hasLoadedOnce = false

    @ObservationIgnored private let backend: any ServerBackend
    @ObservationIgnored private var nextOffset: Int? = 0
    @ObservationIgnored private var generation = 0
    private let pageSize = 100

    public init(backend: any ServerBackend, sources: [LogSource] = [.system, .connection], backupTask: String? = nil) {
        self.backend = backend
        self.sources = sources.isEmpty ? [.system] : sources
        self.backupTask = backupTask
        let first = self.sources[0]
        source = first
        // Backups run nightly: a day is often just one run.
        timeframe = first == .backup ? .lastWeek : .lastDay
    }

    public var filterKey: FilterKey {
        FilterKey(source: source, search: searchText.trimmingCharacters(in: .whitespaces), timeframe: timeframe, levels: levels)
    }

    public var canLoadMore: Bool { nextOffset != nil }

    public func reload() async {
        generation += 1
        entries = []
        nextOffset = 0
        error = nil
        await loadPage(generation: generation)
        hasLoadedOnce = true
    }

    public func loadMore() async {
        guard !isLoading, nextOffset != nil else { return }
        await loadPage(generation: generation)
    }

    private func loadPage(generation: Int) async {
        guard let offset = nextOffset else { return }
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        let keyword = filterKey.search
        let query = LogQuery(
            source: source,
            offset: offset,
            limit: pageSize,
            keyword: keyword.isEmpty ? nil : keyword,
            levels: levels,
            from: timeframe.startDate(),
            to: nil,
            backupTask: backupTask
        )
        do {
            let page = try await backend.logs(query)
            guard generation == self.generation else { return }
            entries += page.entries
            total = page.total
            nextOffset = page.nextOffset
        } catch {
            guard generation == self.generation else { return }
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
            nextOffset = nil
        }
    }

    public func toggle(_ level: LogLevel) {
        if levels.contains(level) {
            guard levels.count > 1 else { return }
            levels.remove(level)
        } else {
            levels.insert(level)
        }
    }

    /// Plain-text export of the loaded entries.
    public var exportText: String {
        entries.map { entry in
            let date = entry.date?.formatted(.iso8601) ?? "-"
            return "\(date)\t\(entry.level.rawValue.uppercased())\t\(entry.category)\t\(entry.user ?? "-")\t\(entry.message)"
        }
        .joined(separator: "\n")
    }
}

public struct LogsView: View {
    @State private var model: LogsViewModel

    let backupTitle: LocalizedStringKey

    /// `sources`: the logs this NAS offers; with more than one, a picker switches between them.
    /// `backupTitle`: name of the backup log (Hyper Backup on DSM, backup tasks on Proxmox).
    public init(backend: any ServerBackend, sources: [LogSource] = [.system, .connection], backupTask: String? = nil, backupTitle: LocalizedStringKey = "Hyper Backup") {
        _model = State(initialValue: LogsViewModel(backend: backend, sources: sources, backupTask: backupTask))
        self.backupTitle = backupTitle
    }

    public var body: some View {
        List {
            ForEach(model.entries) { entry in
                LogRow(entry: entry)
                    .onAppear {
                        if entry.id == model.entries.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
            }
            if model.isLoading, !model.entries.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.entries.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Logs unavailable", systemImage: "list.bullet.rectangle", description: Text(error.localizedDescription))
                } else if model.isLoading || !model.hasLoadedOnce {
                    ProgressView()
                } else if !model.filterKey.search.isEmpty {
                    ContentUnavailableView.search(text: model.filterKey.search)
                } else {
                    ContentUnavailableView("No log entries", systemImage: "list.bullet.rectangle", description: Text("Try a longer time range."))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.sources.count > 1 {
                Picker("Log", selection: $model.source) {
                    ForEach(model.sources, id: \.self) { source in
                        (source == .backup ? Text(backupTitle) : Text(source.title)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .searchable(text: $model.searchText, prompt: Text("Search logs"))
        .navigationTitle(model.backupTask.map { Text(verbatim: $0) } ?? (model.sources == [.backup] ? Text(backupTitle) : Text("Logs")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Time Range", selection: $model.timeframe) {
                        ForEach(LogsViewModel.Timeframe.allCases) { Text($0.title).tag($0) }
                    }
                    Section("Severity") {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Toggle(isOn: Binding(get: { model.levels.contains(level) }, set: { _ in model.toggle(level) })) {
                                LogLevelLabel(level: level)
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: model.exportText, subject: Text("Log export")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.entries.isEmpty)
            }
        }
        .refreshable { await model.reload() }
        // Debounced reload whenever search, time range or severity change.
        .task(id: model.filterKey) {
            if model.hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await model.reload()
        }
    }
}

extension LogSource {
    public var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .connection: "Connections"
        case .backup: "Hyper Backup"
        }
    }
}

struct LogLevelLabel: View {
    let level: LogLevel

    var body: some View {
        switch level {
        case .info: Label("Info", systemImage: "info.circle")
        case .warning: Label("Warning", systemImage: "exclamationmark.triangle")
        case .error: Label("Error", systemImage: "xmark.octagon")
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let date = entry.date {
                        Text(date, format: .dateTime.day().month().hour().minute().second())
                    }
                    Text("·")
                    Text(entry.category)
                    if let user = entry.user, !user.isEmpty {
                        Text("·")
                        Text(user)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    NavigationStack {
        LogsView(backend: MockBackend.preview())
    }
}
