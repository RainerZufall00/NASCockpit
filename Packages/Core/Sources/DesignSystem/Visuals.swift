import SwiftUI
import Domain

/// White symbol on a coloured rounded square, like the rows in the iOS Settings app.
public struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat

    public init(_ systemName: String, color: Color, size: CGFloat = 30) {
        self.systemName = systemName
        self.color = color
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// List row label with an icon badge.
public struct BadgeLabel: View {
    let title: Text
    let systemName: String
    let color: Color
    var subtitle: Text?

    public init(_ title: LocalizedStringKey, systemImage: String, color: Color, subtitle: Text? = nil) {
        self.title = Text(title)
        self.systemName = systemImage
        self.color = color
        self.subtitle = subtitle
    }

    public init(verbatim title: String, systemImage: String, color: Color, subtitle: Text? = nil) {
        self.title = Text(verbatim: title)
        self.systemName = systemImage
        self.color = color
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName, color: color)
            VStack(alignment: .leading, spacing: 1) {
                title
                if let subtitle {
                    subtitle.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Circular gauge for a 0…1 value with threshold colours.
public struct GaugeRing: View {
    let title: LocalizedStringKey
    let value: Double?
    var size: CGFloat
    var lineWidth: CGFloat

    public init(_ title: LocalizedStringKey, value: Double?, size: CGFloat = 64, lineWidth: CGFloat = 7) {
        self.title = title
        self.value = value
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: lineWidth)
                if let value {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, value)))
                        .stroke(Palette.usage(value).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: value)
                }
                Text(value.map(Format.percent) ?? "–")
                    .font(.system(size: size * 0.22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value.map(Format.percent) ?? "–"))
    }
}

/// Round avatar with initials; the colour is stable per name.
public struct InitialsAvatar: View {
    let name: String
    var size: CGFloat
    var dimmed: Bool

    public init(_ name: String, size: CGFloat = 36, dimmed: Bool = false) {
        self.name = name
        self.size = size
        self.dimmed = dimmed
    }

    public var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background((dimmed ? Color.gray : Palette.stableColor(for: name)).gradient, in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Small coloured capsule for states like "Disabled" or "Running".
public struct StatusChip: View {
    let text: Text
    let color: Color

    public init(_ text: LocalizedStringKey, color: Color) {
        self.text = Text(text)
        self.color = color
    }

    public init(verbatim text: String, color: Color) {
        self.text = Text(verbatim: text)
        self.color = color
    }

    public var body: some View {
        text
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
    }
}

/// Header card for one NAS: icon, name, model, status and three gauges on a tinted background.
public struct ServerHeroCard: View {
    let model: ServerTileModel
    let subtitle: String?

    public init(model: ServerTileModel, subtitle: String? = nil) {
        self.model = model
        self.subtitle = subtitle
    }

    public var body: some View {
        let tint = Palette.tint(model.colorName)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ServerIcon(systemName: model.iconName, colorName: model.colorName, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.title3.weight(.bold)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    StatusLine(status: model.status, lastReached: model.lastReached)
                }
                Spacer(minLength: 0)
            }
            if model.cpuLoad != nil || model.memoryUsage != nil || model.volumeUsage != nil {
                HStack {
                    GaugeRing("CPU", value: model.cpuLoad)
                    Spacer()
                    GaugeRing("RAM", value: model.memoryUsage)
                    Spacer()
                    GaugeRing("Storage", value: model.volumeUsage)
                }
                .padding(.horizontal, 8)
                .opacity(model.status == .online ? 1 : 0.45)
            }
            if model.hasStorageProblem {
                Label("Storage needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.background.secondary)
                .overlay(
                    LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 24)
                )
        }
        .accessibilityElement(children: .combine)
    }
}

extension Palette {
    /// The same name always gets the same colour (avatars).
    public static func stableColor(for name: String) -> Color {
        let colors = ["blue", "indigo", "purple", "pink", "orange", "green", "teal", "mint"]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tint(colors[sum % colors.count])
    }

    /// Colours for file types in File Station.
    public static func fileColor(for name: String, isDirectory: Bool) -> Color {
        if isDirectory { return .blue }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return .green
        case "mov", "mp4", "mkv", "avi": return .purple
        case "mp3", "flac", "m4a", "wav": return .pink
        case "pdf": return .red
        case "zip", "tar", "gz", "7z": return .brown
        case "txt", "md", "log", "yaml", "yml", "json": return .gray
        default: return .secondary
        }
    }
}

/// Small coloured tile with a symbol, a big value and a caption (used in summary rows).
public struct StatTile: View {
    let value: Text
    let title: Text
    let systemImage: String
    let color: Color

    public init(value: Int, title: LocalizedStringKey, systemImage: String, color: Color) {
        self.value = Text(value, format: .number)
        self.title = Text(title)
        self.systemImage = systemImage
        self.color = color
    }

    public init(text: Text, title: LocalizedStringKey, systemImage: String, color: Color) {
        value = text
        self.title = Text(title)
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            value
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            title
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
