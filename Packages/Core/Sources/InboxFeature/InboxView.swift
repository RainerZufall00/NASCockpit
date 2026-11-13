import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

/// One NAS contributing to the notification inbox.
public struct InboxSource: Identifiable, Sendable {
    public let id: ServerID
    public let name: String
    public let iconName: String
    public let colorName: String
    public let backend: any ServerBackend

    public init(id: ServerID, name: String, iconName: String, colorName: String, backend: any ServerBackend) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorName = colorName
        self.backend = backend
    }
}

@MainActor
@Observable
public final class InboxViewModel {
    public struct Entry: Identifiable, Hashable {
        public let serverID: ServerID
        public let serverName: String
        public let colorName: String
        public let notification: NASNotification
        public var id: String { "\(serverID.uuidString)/\(notification.id)" }
    }

    public struct Failure: Identifiable, Hashable {
        public let id: ServerID
        public let serverName: String
        public let error: BackendError
    }

    public private(set) var entries: [Entry] = []
    public private(set) var failures: [Failure] = []
    public private(set) var hasLoaded = false
    public var problemsOnly = false
    @ObservationIgnored private let sources: [InboxSource]

    public init(sources: [InboxSource]) {
        self.sources = sources
    }

    public var hasSources: Bool { !sources.isEmpty }
    public var showsServerNames: Bool { sources.count > 1 }

    public var visible: [Entry] {
        problemsOnly ? entries.filter { $0.notification.level != .info } : entries
    }

    /// Newest day first; entries inside a day newest first.
    public var days: [(day: Date, entries: [Entry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: visible) { calendar.startOfDay(for: $0.notification.date) }
            .map { (day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    /// All NAS in parallel; one that fails only adds a line and keeps the others.
    public func load() async {
        var loaded: [Entry] = []
        var failed: [Failure] = []
        await withTaskGroup(of: (InboxSource, Result<[NASNotification], BackendError>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source, .success(try await source.backend.notifications()))
                    } catch {
                        return (source, .failure(BackendError(error)))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let items):
                    loaded += items.map { Entry(serverID: source.id, serverName: source.name, colorName: source.colorName, notification: $0) }
                case .failure(let error):
                    failed.append(Failure(id: source.id, serverName: source.name, error: error))
                }
            }
        }
        entries = loaded.sorted { ($0.notification.date, $0.id) > ($1.notification.date, $1.id) }
        failures = failed.sorted { $0.serverName < $1.serverName }
        hasLoaded = true
    }
}

/// The notifications of all connected NAS in one list.
public struct InboxView: View {
    @State private var model: InboxViewModel
    @State private var selected: InboxViewModel.Entry?
    /// Entries newer than this are marked as new. Moves forward when the list is left.
    @AppStorage("inbox.lastSeen") private var lastSeen = 0.0
    @State private var seenAtOpen: Double?

    public init(sources: [InboxSource]) {
        _model = State(initialValue: InboxViewModel(sources: sources))
    }

    public var body: some View {
        List {
            if !model.failures.isEmpty {
                Section {
                    ForEach(model.failures) { failure in
                        Label("\(failure.serverName): \(failure.error.localizedDescription)", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(model.days, id: \.day) { day in
                Section {
                    ForEach(day.entries) { entry in
                        Button {
                            selected = entry
                        } label: {
                            InboxRow(entry: entry, showsServer: model.showsServerNames, isNew: isNew(entry))
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(day.day, format: .dateTime.weekday(.wide).day().month(.wide))
                }
            }
        }
        .overlay {
            if !model.hasSources {
                ContentUnavailableView("No NAS connected", systemImage: "externaldrive.badge.xmark")
            } else if !model.hasLoaded {
                ProgressView()
            } else if model.visible.isEmpty, model.failures.isEmpty {
                ContentUnavailableView(
                    model.problemsOnly ? "No Problems" : "No Notifications",
                    systemImage: model.problemsOnly ? "checkmark.circle" : "bell.slash",
                    description: Text(model.problemsOnly ? "No warnings or errors in the notifications of your NAS." : "Your NAS have not reported anything.")
                )
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Show", selection: $model.problemsOnly) {
                    Label("All", systemImage: "tray.full").tag(false)
                    Label("Problems Only", systemImage: "exclamationmark.triangle").tag(true)
                }
                .pickerStyle(.menu)
            }
        }
        .refreshable { await model.load() }
        .task {
            if seenAtOpen == nil { seenAtOpen = lastSeen }
            await model.load()
        }
        .onDisappear { lastSeen = Date.now.timeIntervalSince1970 }
        .sheet(item: $selected) { entry in
            InboxDetailView(entry: entry)
        }
    }

    private func isNew(_ entry: InboxViewModel.Entry) -> Bool {
        guard let seenAtOpen, seenAtOpen > 0 else { return false }
        return entry.notification.date.timeIntervalSince1970 > seenAtOpen
    }
}

extension LogLevel {
    var inboxSymbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var inboxColor: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

struct InboxRow: View {
    let entry: InboxViewModel.Entry
    let showsServer: Bool
    let isNew: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.notification.level.inboxSymbol)
                .foregroundStyle(entry.notification.level.inboxColor)
                .font(.title3)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.notification.title)
                        .font(.body.weight(.medium))
                    if isNew {
                        Circle().fill(.blue).frame(width: 8, height: 8)
                            .accessibilityLabel("New")
                    }
                    Spacer(minLength: 8)
                    Text(entry.notification.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !entry.notification.message.isEmpty {
                    Text(entry.notification.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showsServer {
                    StatusChip(verbatim: entry.serverName, color: Palette.tint(entry.colorName))
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct InboxDetailView: View {
    let entry: InboxViewModel.Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(entry.notification.title, systemImage: entry.notification.level.inboxSymbol)
                            .font(.headline)
                            .foregroundStyle(entry.notification.level.inboxColor)
                        if !entry.notification.message.isEmpty {
                            Text(entry.notification.message)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("NAS", value: entry.serverName)
                    LabeledContent("Time") {
                        Text(entry.notification.date, format: .dateTime.day().month().year().hour().minute())
                    }
                }
                if !entry.notification.details.isEmpty {
                    Section("Details") {
                        ForEach(entry.notification.details) { detail in
                            LabeledContent(detail.label, value: detail.value)
                        }
                    }
                }
            }
            .navigationTitle("Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    NavigationStack {
        InboxView(sources: DemoData.profiles.prefix(2).compactMap { profile in
            DemoData.spec(for: profile.id).map {
                InboxSource(id: profile.id, name: profile.name, iconName: profile.iconName, colorName: profile.colorName, backend: MockBackend(spec: $0))
            }
        })
    }
}
