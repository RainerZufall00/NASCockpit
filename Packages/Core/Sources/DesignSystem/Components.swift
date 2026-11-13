import SwiftUI
import Domain

public enum Palette {
    public static func tint(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "gray": .gray
        default: .blue
        }
    }

    public static let tintNames = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "gray"]

    /// Green below 75 %, orange below 90 %, red above.
    public static func usage(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .green
        case ..<0.9: .orange
        default: .red
        }
    }

    public static func health(_ status: HealthStatus) -> Color {
        switch status {
        case .normal: .green
        case .warning: .orange
        case .degraded, .crashed: .red
        case .unknown: .secondary
        }
    }
}

/// Horizontal usage bar with threshold colours.
public struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = 6

    public init(fraction: Double, height: CGFloat = 6) {
        self.fraction = fraction
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Palette.usage(fraction).gradient)
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Format.percent(fraction))
    }
}

public struct HealthBadge: View {
    let status: HealthStatus

    public init(_ status: HealthStatus) {
        self.status = status
    }

    public var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.health(status))
            .labelStyle(.titleAndIcon)
    }

    private var title: LocalizedStringKey {
        switch status {
        case .normal: "Healthy"
        case .warning: "Warning"
        case .degraded: "Degraded"
        case .crashed: "Crashed"
        case .unknown: "Unknown"
        }
    }

    private var symbol: String {
        switch status {
        case .normal: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .degraded, .crashed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Small card with an icon, a title and a prominent value.
public struct MetricCard<Footer: View>: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color
    let footer: Footer

    public init(_ title: LocalizedStringKey, value: String, systemImage: String, tint: Color = .accentColor, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// Grouped section with a title, styled like the metric cards.
public struct CardSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}
