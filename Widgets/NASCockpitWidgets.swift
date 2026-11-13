import AppIntents
import SwiftUI
import WidgetKit
import DesignSystem
import Domain
import Persistence

// The widgets only read the app-group status cache. They never see hosts or credentials
// and never talk to a NAS; the app (foreground or background refresh) writes the cache.

@main
struct NASCockpitWidgets: WidgetBundle {
    var body: some Widget {
        ServerStatusWidget()
        PendingUpdatesWidget()
    }
}

enum WidgetData {
    static func load() async -> [CachedServerStatus] {
        await StatusCache(appGroupIdentifier: SharedStorage.appGroup).load().values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Shown in the widget gallery and while loading.
    static let sample = CachedServerStatus(
        serverID: UUID(),
        name: "DiskStation",
        snapshot: SystemSnapshot(
            model: "DS923+",
            osVersion: "DSM 7.2",
            volumes: [VolumeInfo(id: "volume_1", name: "Volume 1", status: .normal, totalBytes: 100, usedBytes: 62)]
        ),
        pendingUpdates: 3,
        lastReached: .now
    )

    static let samples = [
        sample,
        CachedServerStatus(serverID: UUID(), name: "Backup NAS", snapshot: nil, pendingUpdates: 1, lastReached: .now),
        CachedServerStatus(serverID: UUID(), name: "Media", snapshot: nil, pendingUpdates: 0, lastReached: .now),
    ]
}

// MARK: - Configuration

struct ServerEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "NAS"
    static let defaultQuery = ServerQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ status: CachedServerStatus) {
        id = status.serverID.uuidString
        name = status.name
    }
}

struct ServerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        await WidgetData.load().map(ServerEntity.init).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        await WidgetData.load().map(ServerEntity.init)
    }

    func defaultResult() async -> ServerEntity? {
        await WidgetData.load().first.map(ServerEntity.init)
    }
}

struct SelectServerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select NAS"
    static let description = IntentDescription("Choose the NAS this widget shows.")

    @Parameter(title: "NAS")
    var server: ServerEntity?
}

// MARK: - Status of one NAS (small)

struct ServerStatusEntry: TimelineEntry {
    let date: Date
    let status: CachedServerStatus?
}

struct ServerStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ServerStatusEntry {
        ServerStatusEntry(date: .now, status: WidgetData.sample)
    }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> ServerStatusEntry {
        let status = await status(for: configuration)
        return ServerStatusEntry(date: .now, status: status ?? (context.isPreview ? WidgetData.sample : nil))
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<ServerStatusEntry> {
        // The app reloads the timelines whenever it wrote the cache; this is only a fallback.
        Timeline(entries: [ServerStatusEntry(date: .now, status: await status(for: configuration))], policy: .after(.now + 3600))
    }

    private func status(for configuration: SelectServerIntent) async -> CachedServerStatus? {
        let all = await WidgetData.load()
        if let id = configuration.server?.id, let match = all.first(where: { $0.serverID.uuidString == id }) {
            return match
        }
        return all.first
    }
}

struct ServerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ServerStatus", intent: SelectServerIntent.self, provider: ServerStatusProvider()) { entry in
            ServerStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NAS Status")
        .description("Health, storage and open updates of one NAS.")
        .supportedFamilies([.systemSmall])
    }
}

struct ServerStatusView: View {
    let entry: ServerStatusEntry

    var body: some View {
        if let status = entry.status {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    IconBadge(status.iconName ?? "externaldrive.connected.to.line.below", color: Palette.tint(status.colorName ?? "blue"), size: 28)
                    Spacer()
                    HealthLabel(status: status)
                }
                Text(status.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let usage = status.snapshot?.highestVolumeUsage {
                        Gauge(value: usage) {
                            Text("Storage")
                        } currentValueLabel: {
                            Text(Format.percent(usage))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(Palette.usage(usage))
                        .scaleEffect(0.8)
                        .frame(width: 44, height: 44)
                    }
                    if let updates = status.pendingUpdates {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(updates, format: .number)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(updates > 0 ? Color.blue : Color.primary)
                            Text("Updates")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LastReachedLabel(date: status.lastReached)
            }
            .widgetURL(URL(string: "nascockpit://server/\(status.serverID.uuidString)"))
        } else {
            EmptyStateView()
        }
    }
}

struct HealthLabel: View {
    let status: CachedServerStatus

    var body: some View {
        if status.needsLogin {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityLabel("Sign-in required")
        } else if status.snapshot?.hasStorageProblem == true {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Storage problem")
        } else if status.snapshot != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Healthy")
        }
    }
}

/// "Last reached … ago" instead of offline: away from home without VPN every NAS is unreachable.
struct LastReachedLabel: View {
    let date: Date?

    var body: some View {
        Group {
            if let date {
                Label {
                    Text(date, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
            } else {
                Text("Open the app to refresh")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add a NAS in the app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Open updates across all NAS (medium)

struct PendingUpdatesEntry: TimelineEntry {
    let date: Date
    let servers: [CachedServerStatus]
}

struct PendingUpdatesProvider: TimelineProvider {
    func placeholder(in context: Context) -> PendingUpdatesEntry {
        PendingUpdatesEntry(date: .now, servers: WidgetData.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PendingUpdatesEntry) -> Void) {
        let isPreview = context.isPreview
        Task {
            let servers = await WidgetData.load()
            completion(PendingUpdatesEntry(date: .now, servers: servers.isEmpty && isPreview ? WidgetData.samples : servers))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PendingUpdatesEntry>) -> Void) {
        Task {
            let entry = PendingUpdatesEntry(date: .now, servers: await WidgetData.load())
            completion(Timeline(entries: [entry], policy: .after(.now + 3600)))
        }
    }
}

struct PendingUpdatesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PendingUpdates", provider: PendingUpdatesProvider()) { entry in
            PendingUpdatesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Open Updates")
        .description("All NAS with their open package and DSM updates.")
        .supportedFamilies([.systemMedium])
    }
}

struct PendingUpdatesView: View {
    let entry: PendingUpdatesEntry

    private static let maxRows = 4

    /// NAS with open updates or a needed sign-in first.
    private var rows: [CachedServerStatus] {
        entry.servers.sorted {
            let left = ($0.pendingUpdates ?? 0, $0.needsLogin ? 1 : 0)
            let right = ($1.pendingUpdates ?? 0, $1.needsLogin ? 1 : 0)
            return left > right
        }
    }

    private var total: Int { entry.servers.compactMap(\.pendingUpdates).reduce(0, +) }

    var body: some View {
        if entry.servers.isEmpty {
            EmptyStateView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Updates", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)
                    Spacer()
                    if total > 0 {
                        Text(total, format: .number)
                            .font(.headline)
                    } else {
                        Label("All up to date", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                ForEach(rows.prefix(Self.maxRows), id: \.serverID) { server in
                    HStack(spacing: 8) {
                        IconBadge(server.iconName ?? "externaldrive.connected.to.line.below", color: Palette.tint(server.colorName ?? "blue"), size: 20)
                        Text(server.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if server.needsLogin {
                            Text("Sign-in required")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let updates = server.pendingUpdates, updates > 0 {
                            StatusChip(verbatim: updates.formatted(), color: .blue)
                        } else if server.pendingUpdates != nil {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            Text("–").foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if rows.count > Self.maxRows {
                    Text("+ \(rows.count - Self.maxRows) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .widgetURL(URL(string: "nascockpit://updates"))
        }
    }
}
