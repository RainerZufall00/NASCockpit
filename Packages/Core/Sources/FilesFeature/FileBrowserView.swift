import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

/// A copy or move waiting for confirmation.
struct PendingTransfer: Identifiable, Equatable {
    let item: FileItem
    let destination: String
    let mode: TransferMode

    var id: String { "\(mode.rawValue)|\(item.path)|\(destination)" }

    var title: String {
        switch mode {
        case .copy: String(localized: "Copy “\(item.name)”?")
        case .move: String(localized: "Move “\(item.name)”?")
        }
    }

    var operationTitle: String {
        switch mode {
        case .copy: String(localized: "Copy \(item.name) to \(destination)")
        case .move: String(localized: "Move \(item.name) to \(destination)")
        }
    }

    func message(serverName: String) -> String {
        let action = mode == .copy
            ? String(localized: "“\(item.name)” will be copied to “\(destination)” on “\(serverName)”.")
            : String(localized: "“\(item.name)” will be moved from “\(item.parentPath)” to “\(destination)” on “\(serverName)”.")
        return action + " " + String(localized: "Items with the same name in the destination are skipped, nothing is replaced.")
    }
}

/// A confirmation a row is showing.
enum RowPrompt {
    case transfer(PendingTransfer)
    case delete(FileItem)

    var title: String {
        switch self {
        case .transfer(let transfer): transfer.title
        case .delete(let item): String(localized: "Delete “\(item.name)”?")
        }
    }

    func message(serverName: String) -> String {
        switch self {
        case .transfer(let transfer):
            transfer.message(serverName: serverName)
        case .delete(let item):
            item.isDirectory
                ? String(localized: "The folder “\(item.name)” and everything inside it will be deleted on “\(serverName)”. This cannot be undone.")
                : String(localized: "The file “\(item.name)” will be deleted on “\(serverName)”. This cannot be undone.")
        }
    }
}

/// Root of File Station: the shared folders.
public struct FileBrowserView: View {
    let backend: any ServerBackend
    let serverName: String

    public init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    public var body: some View {
        FolderView(backend: backend, serverName: serverName, path: "/", title: String(localized: "File Station"))
    }
}

@MainActor
@Observable
final class FolderModel {
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var error: BackendError?
    private(set) var denied: Set<WriteAction> = []

    @ObservationIgnored let backend: any ServerBackend
    let path: String

    init(backend: any ServerBackend, path: String) {
        self.backend = backend
        self.path = path
    }

    var isRoot: Bool { path == "/" }

    func load(foldersOnly: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = isRoot ? try await backend.sharedFolders() : try await backend.folderContents(path)
            items = foldersOnly ? all.filter(\.isDirectory) : all
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
        denied = await backend.deniedActions()
    }
}

struct FolderView: View {
    let serverName: String
    let title: String
    @State private var model: FolderModel
    @State private var searchText = ""
    @State private var picking: (item: FileItem, mode: TransferMode)?
    @State private var staged: PendingTransfer?
    @State private var pending: PendingTransfer?
    @State private var pendingDelete: FileItem?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var failure: String?
    @Environment(OperationCenter.self) private var center

    init(backend: any ServerBackend, serverName: String, path: String, title: String) {
        self.serverName = serverName
        self.title = title
        _model = State(initialValue: FolderModel(backend: backend, path: path))
    }

    private var filtered: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(filtered) { item in
            row(item)
        }
        .overlay {
            if model.items.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: Text("Search this folder"))
        .navigationTitle(title)
        .toolbar {
            if !model.isRoot {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showNewFolder = true
                    }
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
                .disabled(!FileValidation.isValidName(newFolderName))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In “\(model.path)” on “\(serverName)”.")
        }
        .alert("Action failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), onDismiss: {
            // Ask only after the picker is gone, so the dialog can anchor to the row.
            pending = staged
            staged = nil
        }) {
            if let picking {
                FolderPickerView(backend: model.backend, serverName: serverName, item: picking.item, mode: picking.mode) { destination in
                    staged = PendingTransfer(item: picking.item, destination: destination, mode: picking.mode)
                    self.picking = nil
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: center.completedCount) { Task { await model.load() } }
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        let operation = visibleOperation(for: item)
        let busy = isBusy(item)
        Group {
            if item.isDirectory {
                NavigationLink {
                    FolderView(backend: model.backend, serverName: serverName, path: item.path, title: item.name)
                } label: {
                    FileRow(item: item, isShare: model.isRoot, operation: operation)
                }
            } else {
                FileRow(item: item, isShare: false, operation: operation)
            }
        }
        .swipeActions(edge: .trailing) {
            if !model.isRoot, !busy {
                if canDelete {
                    // Asked once the swipe cell has closed, so the dialog can anchor to the row (like copy/move).
                    Button("Delete", systemImage: "trash") { askDelete(item) }
                        .tint(.red)
                }
                transferButtons(item)
            }
        }
        .contextMenu {
            if !model.isRoot, !busy {
                transferButtons(item)
                if canDelete {
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = item }
                }
            }
        }
        // One dialog per row: two `confirmationDialog` modifiers on the same view would cancel each other out.
        .confirmationDialog(
            prompt(for: item)?.title ?? "",
            isPresented: Binding(get: { prompt(for: item) != nil }, set: { if !$0 { pending = nil; pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: prompt(for: item)
        ) { prompt in
            switch prompt {
            case .transfer(let transfer):
                Button(transfer.mode == .copy ? "Copy" : "Move") { run(transfer) }
            case .delete(let target):
                Button("Delete", role: .destructive) { confirmDelete(target) }
            }
        } message: { prompt in
            Text(prompt.message(serverName: serverName))
        }
    }

    private var canDelete: Bool { !model.denied.contains(.deleteFiles) }

    private func askDelete(_ item: FileItem) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            pendingDelete = item
        }
    }

    /// What the row is asking about right now, if anything.
    private func prompt(for item: FileItem) -> RowPrompt? {
        if let pending, pending.item.path == item.path { return .transfer(pending) }
        if let pendingDelete, pendingDelete.path == item.path { return .delete(pendingDelete) }
        return nil
    }

    @ViewBuilder
    private func transferButtons(_ item: FileItem) -> some View {
        Button("Move to…", systemImage: "folder") { picking = (item, .move) }
            .tint(.orange)
        Button("Copy to…", systemImage: "doc.on.doc") { picking = (item, .copy) }
            .tint(.blue)
    }

    private func kinds(_ item: FileItem) -> [OperationCenter.Kind] {
        [.fileTransfer(.copy, path: item.path), .fileTransfer(.move, path: item.path), .fileDelete(path: item.path)]
    }

    private func isBusy(_ item: FileItem) -> Bool {
        kinds(item).contains { center.isBusy($0, on: model.backend.serverID) }
    }

    private func visibleOperation(for item: FileItem) -> OperationCenter.Operation? {
        kinds(item).compactMap { center.visible($0, on: model.backend.serverID) }.max { $0.createdAt < $1.createdAt }
    }

    private func run(_ transfer: PendingTransfer) {
        let backend = model.backend
        center.enqueue(serverID: backend.serverID, serverName: serverName, kind: .fileTransfer(transfer.mode, path: transfer.item.path), title: transfer.operationTitle) { progress in
            try await backend.transfer(transfer.item.path, to: transfer.destination, mode: transfer.mode, progress: progress)
        }
    }

    /// Deleting is destructive: Face ID / passcode first, then the delete runs in the operation queue.
    private func confirmDelete(_ item: FileItem) {
        let backend = model.backend
        let name = serverName
        Task {
            guard await center.authorize(String(localized: "Delete “\(item.name)” on \(name)")) else { return }
            center.enqueue(serverID: backend.serverID, serverName: name, kind: .fileDelete(path: item.path),
                           title: String(localized: "Delete \(item.name)")) { progress in
                try await backend.delete([item.path], progress: progress)
            }
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        do {
            try await model.backend.createFolder(named: name, in: model.path)
        } catch {
            failure = BackendError(error).localizedDescription
        }
        await model.load()
    }
}

struct FileRow: View {
    let item: FileItem
    let isShare: Bool
    var operation: OperationCenter.Operation?

    var body: some View {
        HStack(spacing: 12) {
            if isShare {
                IconBadge("externaldrive.fill", color: .indigo, size: 34)
            } else {
                IconBadge(item.isDirectory ? "folder.fill" : FileRow.symbol(for: item.name),
                          color: Palette.fileColor(for: item.name, isDirectory: item.isDirectory), size: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let size = item.size { Text(Format.bytes(size)) }
                    if let modified = item.modified {
                        Text(modified, format: .dateTime.day().month().year())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let operation {
                    OperationErrorText(operation)
                }
            }
            Spacer(minLength: 0)
            if let operation {
                OperationStatusView(operation)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": "photo.fill"
        case "mov", "mp4", "mkv", "avi": "film.fill"
        case "mp3", "flac", "m4a", "wav": "music.note"
        case "pdf": "doc.richtext.fill"
        case "zip", "tar", "gz", "7z": "doc.zipper"
        case "txt", "md", "log", "yaml", "yml", "json": "doc.text.fill"
        default: "doc.fill"
        }
    }
}

#Preview {
    NavigationStack {
        FileBrowserView(backend: MockBackend.preview(), serverName: "Home NAS")
    }
    .environment(OperationCenter())
}
