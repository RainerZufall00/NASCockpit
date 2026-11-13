import SwiftUI
import Domain

/// Everything a server tile shows. Built by the app from the connection runtime.
public struct ServerTileModel: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case online
        case connecting
        case attention(String)
        case offline(String)
    }

    public var id: ServerID
    public var name: String
    public var iconName: String
    public var colorName: String
    public var status: Status
    public var model: String?
    public var cpuLoad: Double?
    public var memoryUsage: Double?
    public var volumeUsage: Double?
    public var pendingUpdates: Int?
    public var hasStorageProblem: Bool
    public var lastReached: Date?

    public init(id: ServerID, name: String, iconName: String, colorName: String, status: Status, model: String? = nil, cpuLoad: Double? = nil, memoryUsage: Double? = nil, volumeUsage: Double? = nil, pendingUpdates: Int? = nil, hasStorageProblem: Bool = false, lastReached: Date? = nil) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorName = colorName
        self.status = status
        self.model = model
        self.cpuLoad = cpuLoad
        self.memoryUsage = memoryUsage
        self.volumeUsage = volumeUsage
        self.pendingUpdates = pendingUpdates
        self.hasStorageProblem = hasStorageProblem
        self.lastReached = lastReached
    }
}

public struct ServerIcon: View {
    let systemName: String
    let colorName: String
    var size: CGFloat = 36

    public init(systemName: String, colorName: String, size: CGFloat = 36) {
        self.systemName = systemName
        self.colorName = colorName
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.tint(colorName).gradient, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

public struct StatusLine: View {
    let status: ServerTileModel.Status
    let lastReached: Date?

    public init(status: ServerTileModel.Status, lastReached: Date?) {
        self.status = status
        self.lastReached = lastReached
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            text
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .connecting: .yellow
        case .attention: .orange
        case .offline: .red
        }
    }

    @ViewBuilder private var text: some View {
        switch status {
        case .online: Text("Online")
        case .connecting: Text("Connecting…")
        case .attention(let message): Text(message)
        case .offline(let message):
            if let lastReached {
                Text("\(message) · last reached \(lastReached, format: .relative(presentation: .named))")
            } else {
                Text(message)
            }
        }
    }
}

/// Large tile for the "All NAS" overview.
public struct ServerTileView: View {
    let model: ServerTileModel
    /// When set, the update badge is its own button (e.g. opens the update list).
    let onUpdates: (() -> Void)?

    public init(model: ServerTileModel, onUpdates: (() -> Void)? = nil) {
        self.model = model
        self.onUpdates = onUpdates
    }

    public var body: some View {
        let tint = Palette.tint(model.colorName)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ServerIcon(systemName: model.iconName, colorName: model.colorName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline).lineLimit(1)
                    if let name = model.model, model.status == .online {
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    StatusLine(status: model.status, lastReached: model.lastReached)
                }
                Spacer(minLength: 0)
                if let updates = model.pendingUpdates, updates > 0 {
                    let badge = Label("\(updates)", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.gradient, in: .capsule)
                        .accessibilityLabel(Text("\(updates) updates available"))
                    if let onUpdates {
                        Button(action: onUpdates) { badge }
                            .buttonStyle(.plain)
                            .contentShape(.capsule)
                            .accessibilityHint(Text("Shows the updates"))
                    } else {
                        badge
                    }
                }
            }

            if model.cpuLoad != nil || model.memoryUsage != nil || model.volumeUsage != nil {
                HStack {
                    GaugeRing("CPU", value: model.cpuLoad, size: 54, lineWidth: 6)
                    Spacer()
                    GaugeRing("RAM", value: model.memoryUsage, size: 54, lineWidth: 6)
                    Spacer()
                    GaugeRing("Storage", value: model.volumeUsage, size: 54, lineWidth: 6)
                }
                .padding(.horizontal, 10)
                .opacity(model.status == .online ? 1 : 0.45)
            }

            if model.hasStorageProblem {
                Label("Storage needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.background.secondary)
                .overlay(
                    LinearGradient(colors: [tint.opacity(isOffline ? 0.06 : 0.22), tint.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 22)
                )
        }
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private var isOffline: Bool {
        if case .offline = model.status { return true }
        return false
    }
}

/// Compact row for the sidebar.
public struct ServerRowView: View {
    let model: ServerTileModel
    /// When set, the update count is a small button of its own instead of the plain list badge.
    let onUpdates: (() -> Void)?

    public init(model: ServerTileModel, onUpdates: (() -> Void)? = nil) {
        self.model = model
        self.onUpdates = onUpdates
    }

    public var body: some View {
        HStack(spacing: 12) {
            ServerIcon(systemName: model.iconName, colorName: model.colorName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.body.weight(.medium)).lineLimit(1)
                StatusLine(status: model.status, lastReached: model.lastReached)
                if model.status == .online, let cpu = model.cpuLoad, let memory = model.memoryUsage {
                    Text("CPU \(Format.percent(cpu)) · RAM \(Format.percent(memory))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if model.hasStorageProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("Storage needs attention"))
            }
            if let onUpdates, let updates = model.pendingUpdates, updates > 0 {
                Button(action: onUpdates) {
                    Label("\(updates)", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.gradient, in: .capsule)
                }
                // Borderless keeps the button tappable on its own inside a list row.
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("\(updates) updates available"))
                .accessibilityHint(Text("Shows the updates"))
            }
        }
        // The separator starts under the name, not under the update button's label.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 44 }
        .badge(onUpdates == nil ? (model.pendingUpdates ?? 0) : 0)
    }
}
