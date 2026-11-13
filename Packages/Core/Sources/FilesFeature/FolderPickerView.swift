import SwiftUI
import Domain
import DesignSystem

/// Sheet to choose the destination folder for a copy or move.
struct FolderPickerView: View {
    let backend: any ServerBackend
    let serverName: String
    let item: FileItem
    let mode: TransferMode
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PickerFolderList(
                backend: backend, serverName: serverName, path: "/",
                title: mode == .copy ? String(localized: "Copy “\(item.name)” to …") : String(localized: "Move “\(item.name)” to …"),
                item: item, mode: mode, onPick: onPick, onCancel: { dismiss() }
            )
        }
    }
}

private struct PickerFolderList: View {
    let serverName: String
    let title: String
    let item: FileItem
    let mode: TransferMode
    let onPick: (String) -> Void
    let onCancel: () -> Void
    @State private var model: FolderModel
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var failure: String?

    init(backend: any ServerBackend, serverName: String, path: String, title: String, item: FileItem, mode: TransferMode,
         onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.serverName = serverName
        self.title = title
        self.item = item
        self.mode = mode
        self.onPick = onPick
        self.onCancel = onCancel
        _model = State(initialValue: FolderModel(backend: backend, path: path))
    }

    private var canPickHere: Bool {
        FileValidation.canTransfer(item, to: model.path, mode: mode)
    }

    var body: some View {
        List(model.items) { folder in
            // The item itself cannot be the destination (or contain it).
            let blocked = folder.path == item.path
            NavigationLink {
                PickerFolderList(backend: model.backend, serverName: serverName, path: folder.path, title: folder.name, item: item, mode: mode, onPick: onPick, onCancel: onCancel)
            } label: {
                BadgeLabel(verbatim: folder.name, systemImage: model.isRoot ? "externaldrive.fill" : "folder.fill", color: model.isRoot ? .indigo : .blue)
            }
            .disabled(blocked)
        }
        .overlay {
            if model.items.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No subfolders", systemImage: "folder")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.isRoot {
                Button {
                    onPick(model.path)
                } label: {
                    Text(mode == .copy ? "Copy Here" : "Move Here").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canPickHere)
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            // dismiss() inside a pushed view would only go back one level.
            ToolbarItem(placement: .cancellationAction) {
                if model.isRoot { Button("Cancel", role: .cancel, action: onCancel) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !model.isRoot { Button("Cancel", role: .cancel, action: onCancel) }
            }
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
        .task { await model.load(foldersOnly: true) }
    }

    private func createFolder() async {
        do {
            try await model.backend.createFolder(named: newFolderName.trimmingCharacters(in: .whitespaces), in: model.path)
        } catch {
            failure = BackendError(error).localizedDescription
        }
        await model.load(foldersOnly: true)
    }
}
