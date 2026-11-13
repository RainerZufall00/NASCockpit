import SwiftUI
import Observation
import Domain
import DesignSystem
import DemoBackend

@MainActor
@Observable
final class UsersModel {
    private(set) var users: [NASUser] = []
    private(set) var signedIn = ""
    private(set) var error: BackendError?
    private(set) var isLoading = false
    private(set) var saving: String?
    var failure: String?

    @ObservationIgnored let backend: any ServerBackend
    let serverName: String

    init(backend: any ServerBackend, serverName: String) {
        self.backend = backend
        self.serverName = serverName
    }

    func user(named name: String) -> NASUser? { users.first { $0.name == name } }

    func isSelf(_ user: NASUser) -> Bool {
        user.name.caseInsensitiveCompare(signedIn) == .orderedSame
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        signedIn = await backend.signedInUser()
        do {
            users = try await backend.users()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }

    /// Disabling asks for Face ID first: locking an account out is security relevant.
    func toggle(_ user: NASUser, authorize: (String) async -> Bool) async {
        if !user.isDisabled {
            guard await authorize(String(localized: "Disable \(user.name) on \(serverName)")) else { return }
        }
        saving = user.name
        defer { saving = nil }
        do {
            try await backend.setUser(user.name, disabled: !user.isDisabled)
        } catch {
            failure = BackendError(error).localizedDescription
        }
        await load()
    }
}

/// DSM accounts with disable / enable. The account the app signs in with cannot be disabled here.
struct UsersView: View {
    @State private var model: UsersModel
    @State private var pending: NASUser?
    @State private var searchText = ""
    @Environment(OperationCenter.self) private var center

    init(backend: any ServerBackend, serverName: String) {
        _model = State(initialValue: UsersModel(backend: backend, serverName: serverName))
    }

    private var filtered: [NASUser] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.users }
        return model.users.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.fullName?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        List {
            let active = filtered.filter { !$0.isDisabled }
            let disabled = filtered.filter(\.isDisabled)
            if !active.isEmpty {
                Section("Active") { ForEach(active) { row($0) } }
            }
            if !disabled.isEmpty {
                Section("Disabled") { ForEach(disabled) { row($0) } }
            }
        }
        .overlay {
            if model.users.isEmpty {
                if let error = model.error {
                    ContentUnavailableView("Users unavailable", systemImage: "person.2", description: Text(error.localizedDescription))
                } else if model.isLoading {
                    ProgressView()
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: Text("Search users"))
        .navigationTitle("Users")
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("Change failed", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    private func row(_ user: NASUser) -> some View {
        let isSelf = model.isSelf(user)
        return NavigationLink {
            UserDetailView(model: model, name: user.name)
        } label: {
            UserRow(user: user, isSelf: isSelf, isSaving: model.saving == user.name)
        }
        .userConfirmation(for: $pending, user: user, serverName: model.serverName) { user in
            Task { await model.toggle(user, authorize: center.authorize) }
        }
        .swipeActions {
            if !isSelf, model.saving == nil { actionButton(user) }
        }
        .contextMenu {
            if !isSelf, model.saving == nil { actionButton(user) }
        }
    }

    private func actionButton(_ user: NASUser) -> some View {
        Button(user.isDisabled ? "Enable" : "Disable", systemImage: user.isDisabled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark") {
            pending = user
        }
        .tint(user.isDisabled ? .green : .red)
    }
}

struct UserRow: View {
    let user: NASUser
    let isSelf: Bool
    let isSaving: Bool

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(user.name, size: 38, dimmed: user.isDisabled)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.name).font(.body.weight(.medium))
                    if isSelf { StatusChip("This app", color: .accentColor) }
                }
                if let detail = user.fullName ?? user.email {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSaving {
                ProgressView()
            } else if user.isDisabled {
                StatusChip("Disabled", color: .red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One account with a clearly visible action button.
struct UserDetailView: View {
    let model: UsersModel
    let name: String
    @State private var pending: NASUser?
    @Environment(OperationCenter.self) private var center

    var body: some View {
        if let user = model.user(named: name) {
            let isSelf = model.isSelf(user)
            List {
                Section {
                    VStack(spacing: 10) {
                        InitialsAvatar(user.name, size: 80, dimmed: user.isDisabled)
                        Text(user.name).font(.title2.weight(.bold))
                        if let fullName = user.fullName { Text(fullName).foregroundStyle(.secondary) }
                        StatusChip(user.isDisabled ? "Disabled" : "Active", color: user.isDisabled ? .red : .green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    if let email = user.email { LabeledContent("Email", value: email) }
                    LabeledContent("NAS", value: model.serverName)
                }
                Section {
                    if isSelf {
                        Label("The app is signed in with this account, so it cannot be disabled here.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(role: user.isDisabled ? nil : .destructive) {
                            pending = user
                        } label: {
                            HStack {
                                Label(user.isDisabled ? "Enable Account" : "Disable Account",
                                      systemImage: user.isDisabled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                                Spacer()
                                if model.saving == user.name { ProgressView() }
                            }
                        }
                        .disabled(model.saving != nil)
                        .userConfirmation(for: $pending, user: user, serverName: model.serverName) { user in
                            Task { await model.toggle(user, authorize: center.authorize) }
                        }
                    }
                } footer: {
                    if !isSelf {
                        Text(user.isDisabled
                             ? "The account can sign in again."
                             : "The account can no longer sign in, e.g. after a lost device. Disabling asks for Face ID.")
                    }
                }
            }
            .navigationTitle(user.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("User not found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

extension View {
    func userConfirmation(for pending: Binding<NASUser?>, user: NASUser, serverName: String, run: @escaping (NASUser) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue.map { $0.isDisabled ? String(localized: "Enable \($0.name)?") : String(localized: "Disable \($0.name)?") } ?? "",
            isPresented: Binding(get: { pending.wrappedValue?.name == user.name }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { user in
            Button(user.isDisabled ? "Enable" : "Disable", role: user.isDisabled ? nil : .destructive) { run(user) }
        } message: { user in
            Text(user.isDisabled
                 ? "“\(user.name)” can sign in to “\(serverName)” again."
                 : "“\(user.name)” can no longer sign in to “\(serverName)”. Running sessions of this account may continue until they end.")
        }
    }
}

/// Who is signed in to the NAS right now (read-only).
struct ConnectionsView: View {
    let backend: any ServerBackend

    @State private var connections: [ActiveConnection] = []
    @State private var error: BackendError?
    @State private var isLoading = false

    var body: some View {
        List(connections) { connection in
            HStack(spacing: 12) {
                InitialsAvatar(connection.user, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(connection.user).font(.body.weight(.medium))
                        Spacer()
                        StatusChip(verbatim: connection.kind, color: .teal)
                    }
                    HStack {
                        Text(connection.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        if let since = connection.since {
                            Text(since, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .overlay {
            if connections.isEmpty {
                if let error {
                    ContentUnavailableView("Connections unavailable", systemImage: "person.badge.clock", description: Text(error.localizedDescription))
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Nobody signed in", systemImage: "person.badge.clock")
                }
            }
        }
        .navigationTitle("Signed In Now")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await backend.activeConnections()
            error = nil
        } catch {
            let mapped = BackendError(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }
}
