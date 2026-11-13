import SwiftUI
import Domain
import DesignSystem
import DemoBackend

/// Last lines of a container's output (newest first), read-only, with search and export.
public struct ContainerLogsView: View {
    let backend: any ServerBackend
    let container: ContainerItem

    @State private var lines: [ContainerLogLine] = []
    @State private var error: BackendError?
    @State private var isLoading = false
    @State private var searchText = ""

    static let limit = 500

    public init(backend: any ServerBackend, container: ContainerItem) {
        self.backend = backend
        self.container = container
    }

    private var filtered: [ContainerLogLine] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        List {
            Section {
                LabeledContent("Status") { ContainerStatusChip(item: container) }
                if let image = container.image {
                    LabeledContent("Image", value: image)
                }
                if let project = container.projectName {
                    LabeledContent("Project", value: project)
                }
            }
            Section("Output") {
                ForEach(filtered) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        if let date = line.date {
                            Text(date, format: .dateTime.day().month().hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.stream == "stderr" ? .red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .overlay {
            if lines.isEmpty {
                if let error {
                    ContentUnavailableView("Log unavailable", systemImage: "text.alignleft", description: Text(error.localizedDescription))
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No output", systemImage: "text.alignleft")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: Text("Search output"))
        .navigationTitle(container.name)
        .toolbar {
            if !lines.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: export, preview: SharePreview("\(container.name).log"))
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var export: String {
        lines.reversed().map { line in
            let date = line.date.map { $0.formatted(.iso8601) } ?? "-"
            return "\(date) [\(line.stream ?? "-")] \(line.text)"
        }
        .joined(separator: "\n")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            lines = try await backend.containerLogs(container.name, limit: Self.limit)
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }
}

#Preview {
    NavigationStack {
        ContainerLogsView(backend: MockBackend.preview(), container: DemoData.servers[0].containers[2])
    }
}
