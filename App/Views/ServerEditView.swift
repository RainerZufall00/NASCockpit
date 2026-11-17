import SwiftUI
import Observation
import Domain

/// "Edit Server": name, colour, addresses, account and the trusted certificate of an existing server.
@MainActor
@Observable
final class ServerEditModel {
    typealias AddressDraft = AddServerModel.AddressDraft

    let original: ServerProfile
    var name: String
    var colorName: String
    var addresses: [AddressDraft]
    var username: String
    var newPassword = ""
    private(set) var forgetsCertificate = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    init(profile: ServerProfile) {
        original = profile
        name = profile.name
        colorName = profile.colorName
        addresses = profile.addresses.map {
            AddressDraft(id: $0.id, host: $0.host, port: String($0.port), label: $0.label, usesHTTPS: $0.usesHTTPS)
        }
        username = profile.username
    }

    var isProxmox: Bool { original.backend == .proxmox }

    /// Only a password account can change its user here; tokens and OpenID are set up when adding the server.
    var canEditAccount: Bool { original.authMethod == .password }

    private var trimmedUsername: String {
        var user = username.trimmingCharacters(in: .whitespaces)
        if isProxmox, !user.isEmpty, !user.contains("@") { user += "@pam" }
        return user
    }

    var accountChanged: Bool { canEditAccount && trimmedUsername != original.username }

    var invalidAddress: Bool {
        addresses.contains { !$0.trimmedHost.isEmpty && $0.address == nil }
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !addresses.compactMap(\.address).isEmpty
            && !invalidAddress
            && (!canEditAccount || !trimmedUsername.isEmpty)
            && (!accountChanged || !newPassword.isEmpty)
            && !isSaving
    }

    func forgetCertificate() {
        forgetsCertificate = true
    }

    func save(into manager: ConnectionManager) async -> Bool {
        var profile = original
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.colorName = colorName
        profile.addresses = addresses.compactMap(\.address)
        if canEditAccount { profile.username = trimmedUsername }
        if forgetsCertificate {
            profile.pinnedSPKI = nil
            profile.trustedCertificateName = nil
        }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await manager.updateServer(profile, newPassword: canEditAccount && !newPassword.isEmpty ? newPassword : nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct ServerEditView: View {
    let manager: ConnectionManager
    @State private var model: ServerEditModel
    @Environment(\.dismiss) private var dismiss

    init(manager: ConnectionManager, profile: ServerProfile) {
        self.manager = manager
        _model = State(initialValue: ServerEditModel(profile: profile))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .textInputAutocapitalization(.words)
                    ColorSwatchPicker(selection: $model.colorName)
                }
                addressSection
                if model.canEditAccount {
                    accountSection
                } else {
                    Section("Account") {
                        LabeledContent("User", value: model.original.username.isEmpty ? "–" : model.original.username)
                    }
                }
                certificateSection
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(model.isSaving)
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                if await model.save(into: manager) { dismiss() }
                            }
                        }
                        .disabled(!model.canSave)
                    }
                }
            }
        }
    }

    private var addressSection: some View {
        Section {
            ForEach($model.addresses) { $address in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Host or IP", text: $address.host, prompt: Text(model.isProxmox ? "pve.local or 192.168.1.20" : "nas.local or 192.168.1.10"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if address.id == model.original.lastReachedAddressID {
                            Text("Last reached")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: .capsule)
                        }
                    }
                    HStack {
                        TextField("Port", text: $address.port)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                        Divider()
                        TextField("Label", text: $address.label, prompt: Text("LAN, Tailscale …"))
                    }
                    if !model.isProxmox {
                        Picker("Connection", selection: $address.usesHTTPS) {
                            Text("HTTPS").tag(true)
                            Text("HTTP").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if address.httpNotAllowed {
                            Label("HTTP is only possible for addresses in your home network or VPN (e.g. 192.168.x.x, 10.x.x.x, Tailscale 100.x.x.x, *.local). Use HTTPS for this address.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .onDelete { model.addresses.remove(atOffsets: $0) }
            .onMove { model.addresses.move(fromOffsets: $0, toOffset: $1) }

            Button("Add Address", systemImage: "plus") {
                model.addresses.append(ServerEditModel.AddressDraft(port: String(model.original.backend.defaultHTTPSPort)))
            }
        } header: {
            HStack {
                Text("Addresses")
                Spacer()
                EditButton().font(.caption)
            }
        } footer: {
            Text("The app tries the last reached address first, then the others in this order. Swipe to delete; tap Edit to reorder.")
        }
    }

    private var accountSection: some View {
        Section {
            TextField(model.isProxmox ? "User" : "Account", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(model.accountChanged ? "Password" : "New Password (optional)", text: $model.newPassword)
                .textContentType(.password)
        } header: {
            Text("Account")
        } footer: {
            if model.accountChanged {
                Text("A different account needs its password.")
            } else {
                Text("Leave the password empty to keep the stored one.")
            }
        }
    }

    @ViewBuilder
    private var certificateSection: some View {
        let profile = model.original
        Section {
            if model.forgetsCertificate || profile.pinnedSPKI == nil {
                Text(model.forgetsCertificate ? "Forgotten when you save. The next connection asks you to confirm the certificate again, unless iOS trusts it on its own." : "None. The server’s certificate is trusted by iOS, or you have not confirmed one yet.")
                    .foregroundStyle(.secondary)
            } else {
                if let name = profile.trustedCertificateName {
                    LabeledContent("Issued for", value: name)
                }
                if let spki = profile.pinnedSPKI {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Public key (SPKI) SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(CertificateInfo.grouped(spki))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Button("Forget Certificate", role: .destructive) { model.forgetCertificate() }
            }
        } header: {
            Text("Trusted Certificate")
        } footer: {
            if !model.forgetsCertificate, let name = profile.trustedCertificateName {
                Text("Publicly trusted certificate: renewals for \(name) are accepted automatically, also when the app connects by IP address.")
            } else if !model.forgetsCertificate, profile.pinnedSPKI != nil {
                Text("The app only accepts this key when iOS does not trust the certificate on its own (self-signed, or reached by IP address).")
            }
        }
    }
}
