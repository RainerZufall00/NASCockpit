import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

// MARK: Presentation helpers

extension SecuritySeverity {
    var title: String {
        switch self {
        case .safe: String(localized: "Safe")
        case .info: String(localized: "Info")
        case .outOfDate: String(localized: "Out of date")
        case .warning: String(localized: "Warning")
        case .risk: String(localized: "Risk")
        case .danger: String(localized: "Danger")
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .info: .blue
        case .outOfDate: .yellow
        case .warning: .orange
        case .risk: .red
        case .danger: .pink
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .info: "info.circle.fill"
        case .outOfDate: "clock.badge.exclamationmark.fill"
        case .warning: "exclamationmark.shield.fill"
        case .risk, .danger: "xmark.shield.fill"
        }
    }
}

extension SecurityCheckGroup {
    var title: String { Self.title(for: id) }

    static func title(for id: String) -> String {
        switch id {
        case "malware": String(localized: "Malware")
        case "systemCheck": String(localized: "System")
        case "securitySetting": String(localized: "Security settings")
        case "userInfo": String(localized: "Accounts and passwords")
        case "network": String(localized: "Network")
        case "update": String(localized: "Updates")
        case "": String(localized: "Other")
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    var symbol: String {
        switch id {
        case "malware": "ladybug.fill"
        case "systemCheck": "gearshape.fill"
        case "securitySetting": "lock.fill"
        case "userInfo": "person.2.fill"
        case "network": "network"
        case "update": "arrow.down.circle.fill"
        default: "checklist"
        }
    }

    /// "6 checks · all passed" or "4 checks · 1 warning".
    var summary: String {
        let checks = total == 1 ? String(localized: "1 check") : String(localized: "\(total) checks")
        guard failedCount > 0 else { return String(localized: "\(checks) · all passed") }
        let parts = failures.sorted { $0.key > $1.key }.map { "\($0.value) \($0.key.title.lowercased())" }
        return "\(checks) · \(parts.joined(separator: ", "))"
    }
}

extension SecurityScanReport {
    var headline: String {
        if isScanning {
            return progress.map { String(localized: "Scanning… \(Int(($0 * 100).rounded())) %") } ?? String(localized: "Scanning…")
        }
        guard hasBeenScanned else { return String(localized: "Not scanned yet") }
        switch issueCount {
        case 0: return failedCount == 0 ? String(localized: "No risks found") : String(localized: "Only notes, no risks")
        case 1: return String(localized: "1 issue found")
        default: return String(localized: "\(issueCount) issues found")
        }
    }

    var tint: Color {
        if isScanning { return .blue }
        guard hasBeenScanned else { return .gray }
        return overall.color
    }

    var symbol: String {
        if isScanning { return "shield.lefthalf.filled" }
        guard hasBeenScanned else { return "shield" }
        return overall.symbol
    }
}

// MARK: Model

@MainActor
@Observable
final class SecurityAdvisorModel {
    private(set) var report: SecurityScanReport?
    private(set) var error: BackendError?
    private(set) var hasLoaded = false

    @ObservationIgnored let backend: any ServerBackend
    let serverName: String

    init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    var isScanning: Bool { report?.isScanning == true }

    func load() async {
        defer { hasLoaded = true }
        do {
            report = try await backend.securityReport()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }

    /// Follows a scan that was started in DSM.
    func pollWhileScanning() async {
        while isScanning, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

// MARK: View

public struct SecurityAdvisorView: View {
    @State private var model: SecurityAdvisorModel

    public init(backend: any ServerBackend, serverName: String) {
        _model = State(initialValue: SecurityAdvisorModel(backend: backend, serverName: serverName))
    }

    public var body: some View {
        List {
            if let report = model.report {
                Section {
                    hero(report)
                        .listRowBackground(Color.clear)
                }
                if !report.findings.isEmpty {
                    Section("Findings") {
                        ForEach(report.findings) { finding in
                            FindingRow(finding: finding)
                        }
                    }
                }
                Section {
                    ForEach(report.groups) { group in
                        CheckGroupRow(group: group, scanning: report.isScanning)
                    }
                    if report.groups.isEmpty {
                        Text("DSM reported no check categories.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Checks")
                } footer: {
                    if report.findings.isEmpty, report.failedCount > 0 {
                        Text("DSM does not name the failed checks here. Open Security Advisor in DSM for details and fixes.")
                    } else {
                        Text("Start a scan and fix findings in DSM → Security Advisor; it shows the steps for each check.")
                    }
                }
            } else if let error = model.error {
                Section {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if !model.hasLoaded { ProgressView() }
        }
        .navigationTitle("Security Advisor")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: model.isScanning) { await model.pollWhileScanning() }
    }

    private func hero(_ report: SecurityScanReport) -> some View {
        VStack(spacing: 10) {
            IconBadge(report.symbol, color: report.tint, size: 72)
                .symbolEffect(.pulse, isActive: report.isScanning)
            Text(report.headline)
                .font(.title2.weight(.bold))
                .contentTransition(.numericText())
                .multilineTextAlignment(.center)
            if report.isScanning {
                ProgressView(value: report.progress ?? 0)
                    .tint(report.tint)
                    .opacity(report.progress == nil ? 0.4 : 1)
                    .padding(.horizontal, 40)
            } else if report.hasBeenScanned {
                StatusChip(verbatim: report.overall.title, color: report.overall.color)
            }
            if let last = report.lastScan {
                Text("Last scan \(last, format: .relative(presentation: .named))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if report.checkCount > 0, !report.isScanning {
                Text("\(report.checkCount - report.failedCount) of \(report.checkCount) checks passed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Rows

struct CheckGroupRow: View {
    let group: SecurityCheckGroup
    let scanning: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(group.symbol, color: scanning ? .blue : group.severity.color, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title).font(.body.weight(.medium))
                    Spacer(minLength: 6)
                    if scanning {
                        if group.isRunning {
                            ProgressView().controlSize(.small)
                        } else if (group.progress ?? 0) >= 1 {
                            Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Done")
                        }
                    } else {
                        StatusChip(verbatim: group.severity.title, color: group.severity.color)
                    }
                }
                if scanning, let progress = group.progress, group.isRunning {
                    ProgressView(value: progress).tint(.blue)
                } else if !scanning {
                    Text(group.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct FindingRow: View {
    let finding: SecurityFinding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: finding.severity.symbol)
                .font(.title3)
                .foregroundStyle(finding.severity.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.body)
                Text(SecurityCheckGroup.title(for: finding.group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            StatusChip(verbatim: finding.severity.title, color: finding.severity.color)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SecurityAdvisorView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
    .environment(OperationCenter())
}
