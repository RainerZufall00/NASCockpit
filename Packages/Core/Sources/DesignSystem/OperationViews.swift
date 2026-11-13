import SwiftUI
import Domain

/// Compact status of one write operation, for list rows.
public struct OperationStatusView: View {
    let operation: OperationCenter.Operation

    public init(_ operation: OperationCenter.Operation) {
        self.operation = operation
    }

    public var body: some View {
        switch operation.status {
        case .queued:
            Label("Waiting", systemImage: "clock")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Waiting"))
        case .running(let progress):
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .accessibilityLabel(Text("In progress"))
                    .accessibilityValue(Text(Format.percent(progress)))
            } else {
                ProgressView().accessibilityLabel(Text("In progress"))
            }
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Done"))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(Text("Failed"))
        }
    }
}

/// Error line under a row whose last operation failed.
public struct OperationErrorText: View {
    let operation: OperationCenter.Operation?

    public init(_ operation: OperationCenter.Operation?) {
        self.operation = operation
    }

    public var body: some View {
        if let operation, case .failed(let error) = operation.status {
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// All operations of this session: running ones first, then finished ones, newest first.
public struct ActivityView: View {
    @Environment(OperationCenter.self) private var center
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                let active = center.operations.filter { !$0.status.isFinished }
                let finished = center.operations.filter(\.status.isFinished).reversed()
                if !active.isEmpty {
                    Section("In Progress") {
                        ForEach(active) { ActivityRow(operation: $0) }
                    }
                }
                if !finished.isEmpty {
                    Section("Finished") {
                        ForEach(Array(finished)) { ActivityRow(operation: $0) }
                    }
                }
            }
            .overlay {
                if center.operations.isEmpty {
                    ContentUnavailableView("No activity", systemImage: "checklist", description: Text("Updates and other actions appear here while they run."))
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { center.clearFinished() }
                        .disabled(!center.operations.contains { $0.status.isFinished })
                }
            }
        }
    }
}

struct ActivityRow: View {
    let operation: OperationCenter.Operation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.title).font(.body.weight(.medium))
                Text(operation.serverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .running(let progress?) = operation.status {
                    ProgressView(value: progress)
                }
                OperationErrorText(operation)
            }
            Spacer(minLength: 0)
            OperationStatusView(operation)
        }
        .accessibilityElement(children: .combine)
    }
}
