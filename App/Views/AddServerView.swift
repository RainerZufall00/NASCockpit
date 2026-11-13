import SwiftUI
import Observation
import DesignSystem
import Domain
import ProxmoxBackend
import SynologyBackend

/// Hints shown once after a server was added.
struct AccountHint: Hashable {
    var kind: BackendKind
    var usesBuiltInAdmin: Bool
    var lacksTwoFactor: Bool
    /// OpenID sign-in: offer to create an API token for unattended sign-ins.
    var offersAPIToken: Bool

    var isEmpty: Bool { !usesBuiltInAdmin && !lacksTwoFactor }
}

@MainActor
@Observable
final class AddServerModel {
    enum Step: Equatable {
        case form
        case connecting
        case trust(CertificateInfo)
        case otp
        case finished(AccountHint)
    }

    enum ProxmoxAuth: String, CaseIterable, Identifiable {
        case password, apiToken, openID
        var id: Self { self }
    }

    struct Realm: Identifiable, Equatable {
        let realm: String
        let type: String
        let comment: String?
        var id: String { realm }
    }

    struct AddressDraft: Identifiable, Equatable {
        let id = UUID()
        var host = ""
        var port = String(ServerAddress.defaultHTTPSPort)
        var label = ""
        var usesHTTPS = true {
            didSet {
                // Follow the DSM defaults when the user did not pick a custom port.
                if usesHTTPS, port == String(ServerAddress.defaultHTTPPort) { port = String(ServerAddress.defaultHTTPSPort) }
                if !usesHTTPS, port == String(ServerAddress.defaultHTTPSPort) { port = String(ServerAddress.defaultHTTPPort) }
            }
        }

        var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// HTTP was chosen for a host outside the local network / VPN.
        var httpNotAllowed: Bool {
            !usesHTTPS && !trimmedHost.isEmpty && !ServerAddress.isPrivateNetworkHost(trimmedHost)
        }

        var address: ServerAddress? {
            guard !trimmedHost.isEmpty, !httpNotAllowed, let port = Int(port), (1...65535).contains(port) else { return nil }
            return ServerAddress(id: id, host: trimmedHost, port: port, label: label.trimmingCharacters(in: .whitespaces), usesHTTPS: usesHTTPS)
        }
    }

    var kind: BackendKind = .synology {
        didSet { switchedKind(from: oldValue) }
    }
    var name = ""
    var addresses: [AddressDraft] = [AddressDraft(label: "LAN")]
    var username = ""
    var password = ""
    var savesPassword = true
    var otp = ""
    var colorName = "blue"

    // Proxmox
    var proxmoxAuth: ProxmoxAuth = .password
    var tokenID = ""
    var tokenSecret = ""
    var realms: [Realm] = []
    var selectedRealm = ""
    private(set) var isLoadingRealms = false
    /// After an OpenID sign-in: create an API token so the app signs in without the browser later.
    var createsAPIToken = true

    private(set) var step: Step = .form
    private(set) var errorMessage: String?
    private(set) var isFinishing = false

    @ObservationIgnored private var profile: ServerProfile?
    @ObservationIgnored private var backend: (any ServerBackend)?
    @ObservationIgnored private let credentials = InMemoryCredentialProvider()
    @ObservationIgnored private var usedOTP = false
    @ObservationIgnored private var adopted = false
    @ObservationIgnored private var pinnedSPKI: String?
    /// The certificate prompt came from loading the realms, not from connecting.
    @ObservationIgnored private var realmsPending = false

    var validAddresses: [ServerAddress] { addresses.compactMap(\.address) }

    var isProxmox: Bool { kind == .proxmox }

    var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !validAddresses.isEmpty, step == .form else { return false }
        switch (kind, proxmoxAuth) {
        case (.synology, _), (.proxmox, .password):
            return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case (.proxmox, .apiToken):
            return tokenID.contains("!") && tokenID.contains("@") && !tokenSecret.isEmpty
        case (.proxmox, .openID):
            return !selectedRealm.isEmpty
        }
    }

    private func switchedKind(from old: BackendKind) {
        guard old != kind else { return }
        for index in addresses.indices {
            if addresses[index].port == String(old.defaultHTTPSPort) || addresses[index].port == String(ServerAddress.defaultHTTPPort) {
                addresses[index].usesHTTPS = true
                addresses[index].port = String(kind.defaultHTTPSPort)
            }
            if kind == .proxmox { addresses[index].usesHTTPS = true }
        }
        if kind == .proxmox, colorName == "blue" { colorName = "orange" }
    }

    private var authMethod: AuthMethod {
        switch (kind, proxmoxAuth) {
        case (.synology, _), (.proxmox, .password): .password
        case (.proxmox, .apiToken): .apiToken
        case (.proxmox, .openID): .openID(realm: selectedRealm)
        }
    }

    func submit() async {
        let account: String
        let secret: String?
        switch authMethod {
        case .password:
            var user = username.trimmingCharacters(in: .whitespaces)
            // Proxmox needs the realm; "pam" is what the web UI defaults to.
            if isProxmox, !user.contains("@") { user += "@pam" }
            account = user
            secret = password
        case .apiToken:
            account = tokenID.trimmingCharacters(in: .whitespaces)
            secret = tokenSecret
        case .openID:
            account = ""
            secret = nil
        }
        let profile = ServerProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            addresses: validAddresses,
            backend: kind,
            authMethod: authMethod,
            username: account,
            pinnedSPKI: pinnedSPKI,
            savesPassword: secret == nil ? false : savesPassword,
            colorName: colorName,
            iconName: isProxmox ? "server.rack" : "externaldrive.connected.to.line.below"
        )
        self.profile = profile
        if let secret {
            await credentials.set(ServerCredentials(password: secret), for: profile.id)
        }
        let backend = BackendFactory.make(for: profile, credentials: credentials, deviceName: ConnectionManager.deviceName, interactive: true)
        if let proxmox = backend as? ProxmoxBackend {
            await proxmox.setInteractiveSignIn(true)
        }
        self.backend = backend
        await attempt(otp: nil)
    }

    func attempt(otp: String?) async {
        guard let backend else { return }
        step = .connecting
        errorMessage = nil
        do {
            try await backend.connect(otp: otp)
            if otp != nil { usedOTP = true }
            let signedIn = await backend.signedInUser()
            step = .finished(AccountHint(
                kind: kind,
                usesBuiltInAdmin: isProxmox ? signedIn.lowercased().hasPrefix("root@") : username.trimmingCharacters(in: .whitespaces).lowercased() == "admin",
                lacksTwoFactor: authMethod == .password && !usedOTP,
                offersAPIToken: authMethod.isOpenID
            ))
        } catch {
            let error = BackendError(error)
            switch error {
            case .certificateUntrusted(let info):
                step = .trust(info)
            case .otpRequired:
                step = .otp
            case .otpInvalid:
                self.otp = ""
                errorMessage = error.localizedDescription
                step = .otp
            case .cancelled:
                step = .form
            default:
                errorMessage = error.localizedDescription
                step = .form
            }
        }
    }

    func trust(_ certificate: CertificateInfo) async {
        pinnedSPKI = certificate.spkiSHA256
        if realmsPending {
            realmsPending = false
            step = .form
            await loadRealms()
            return
        }
        await backend?.trustCertificate(certificate)
        profile?.pinnedSPKI = certificate.spkiSHA256
        await attempt(otp: nil)
    }

    func submitOTP() async {
        let code = otp.filter(\.isNumber)
        guard !code.isEmpty else { return }
        await attempt(otp: code)
    }

    func cancelTrust() {
        realmsPending = false
        step = .form
    }

    /// Asks the host which OpenID realms it offers. Needs no account; may ask to trust the certificate first.
    func loadRealms() async {
        guard isProxmox, !validAddresses.isEmpty else { return }
        isLoadingRealms = true
        defer { isLoadingRealms = false }
        errorMessage = nil
        let probeProfile = ServerProfile(name: "probe", addresses: validAddresses, backend: .proxmox, authMethod: .openID(realm: ""), username: "", pinnedSPKI: pinnedSPKI)
        let probe = ProxmoxBackend(profile: probeProfile, credentials: credentials, deviceName: ConnectionManager.deviceName)
        do {
            let found = try await probe.availableRealms().map { Realm(realm: $0.realm, type: $0.type, comment: $0.comment) }
            realms = found.filter { $0.type == "openid" }
            if realms.isEmpty {
                errorMessage = String(localized: "This host has no OpenID Connect realm. Add one under Datacenter → Permissions → Realms first.")
            } else if !realms.contains(where: { $0.realm == selectedRealm }) {
                selectedRealm = realms[0].realm
            }
        } catch {
            let error = BackendError(error)
            if case .certificateUntrusted(let info) = error {
                realmsPending = true
                step = .trust(info)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func finish(into manager: ConnectionManager) async {
        // "Done" stays tappable while the first refresh runs; a second tap must not add the server twice.
        guard !isFinishing, !adopted else { return }
        isFinishing = true
        defer { isFinishing = false }
        guard var profile, let backend else { return }
        var stored = await credentials.credentials(for: profile.id)

        if profile.authMethod.isOpenID {
            if createsAPIToken, let proxmox = backend as? ProxmoxBackend {
                do {
                    let token = try await proxmox.createAPIToken(name: Self.tokenName)
                    profile.username = token.tokenID
                    profile.savesPassword = true
                    stored = ServerCredentials(password: token.secret)
                    await credentials.set(stored!, for: profile.id)
                } catch {
                    errorMessage = String(localized: "The API token could not be created: \(BackendError(error).localizedDescription) Turn the option off to continue without one.")
                    return
                }
            } else {
                profile.username = await backend.signedInUser()
                profile.savesPassword = false
                stored = ServerCredentials(password: "")
            }
            self.profile = profile
        }
        guard let stored else { return }
        do {
            try await manager.adopt(profile: profile, backend: backend, credentials: stored)
            adopted = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Token names must start with a letter: "nascockpit-iphone".
    static var tokenName: String {
        let device = ConnectionManager.deviceName.lowercased().filter { $0.isLetter || $0.isNumber }
        return "nascockpit-" + (device.isEmpty ? "ios" : String(device.prefix(20)))
    }

    /// Sign out again if the sheet is dismissed before the server was added.
    func abandon() async {
        guard !adopted, let backend else { return }
        await backend.disconnect()
    }

    var isAdopted: Bool { adopted }
}

struct AddServerView: View {
    let manager: ConnectionManager
    @State private var model = AddServerModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .form, .connecting:
                    form
                case .trust(let info):
                    CertificateTrustView(serverName: model.name, certificate: info, previousSPKI: nil) {
                        Task { await model.trust(info) }
                    } onCancel: {
                        model.cancelTrust()
                    }
                case .otp:
                    OTPEntryView(serverName: model.name, code: $model.otp, errorMessage: model.errorMessage, kind: model.kind) {
                        Task { await model.submitOTP() }
                    }
                case .finished(let hint):
                    FinishedView(serverName: model.name, hint: hint, isFinishing: model.isFinishing, createsAPIToken: $model.createsAPIToken, errorMessage: model.errorMessage) {
                        Task {
                            await model.finish(into: manager)
                            if model.isAdopted { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(model.step != .form)
        .onDisappear {
            Task { await model.abandon() }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Type", selection: $model.kind) {
                    Text("Synology DSM").tag(BackendKind.synology)
                    Text("Proxmox VE").tag(BackendKind.proxmox)
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $model.name, prompt: Text(model.isProxmox ? "e.g. Proxmox Lab" : "e.g. Home NAS"))
                    .textInputAutocapitalization(.words)
                ColorSwatchPicker(selection: $model.colorName)
            }

            Section {
                ForEach($model.addresses) { $address in
                    VStack(spacing: 8) {
                        TextField("Host or IP", text: $address.host, prompt: Text(model.isProxmox ? "pve.local or 192.168.1.20" : "nas.local or 192.168.1.10"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
                    model.addresses.append(AddServerModel.AddressDraft(port: String(model.kind.defaultHTTPSPort)))
                }
            } header: {
                Text("Addresses")
            } footer: {
                if model.isProxmox {
                    Text("Proxmox listens on port 8006 and always uses HTTPS. Self-signed certificates are confirmed once by their fingerprint. The app tries the last reached address first, then the others in this order.")
                } else {
                    Text("HTTPS uses DSM port 5001, HTTP port 5000. HTTP is unencrypted and therefore only allowed in your home network or through a VPN such as WireGuard or Tailscale, which encrypts the connection itself. The app tries the last reached address first, then the others in this order.")
                }
            }

            if model.isProxmox {
                proxmoxAccount
            } else {
                synologyAccount
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await model.submit() }
                } label: {
                    HStack {
                        Spacer()
                        if model.step == .connecting {
                            ProgressView()
                        } else {
                            Text(model.isProxmox && model.proxmoxAuth == .openID ? "Sign In with Browser" : "Connect").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!model.canSubmit)
            }
        }
        .disabled(model.step == .connecting)
    }

    private var synologyAccount: some View {
        Section {
            TextField("Account", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $model.password)
                .textContentType(.password)
            Toggle("Save Password", isOn: $model.savesPassword)
        } header: {
            Text("Account")
        } footer: {
            if model.savesPassword {
                Text("Stored only in this device’s Keychain, protected by Face ID or your passcode. Never in backups or iCloud.")
            } else {
                Text("You sign in each time the app starts. Background refresh will not be available for this NAS.")
            }
        }
    }

    @ViewBuilder
    private var proxmoxAccount: some View {
        Section {
            Picker("Sign in with", selection: $model.proxmoxAuth) {
                Text("Password").tag(AddServerModel.ProxmoxAuth.password)
                Text("API Token").tag(AddServerModel.ProxmoxAuth.apiToken)
                Text("OpenID Connect").tag(AddServerModel.ProxmoxAuth.openID)
            }
            switch model.proxmoxAuth {
            case .password:
                TextField("User", text: $model.username, prompt: Text("root@pam or admin@pve"))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                Toggle("Save Password", isOn: $model.savesPassword)
            case .apiToken:
                TextField("Token ID", text: $model.tokenID, prompt: Text("user@pam!nascockpit"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret", text: $model.tokenSecret)
                Toggle("Save Secret", isOn: $model.savesPassword)
            case .openID:
                if model.realms.isEmpty {
                    Button {
                        Task { await model.loadRealms() }
                    } label: {
                        HStack {
                            Label("Load Realms from Host", systemImage: "person.badge.key")
                            if model.isLoadingRealms { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.validAddresses.isEmpty || model.isLoadingRealms)
                } else {
                    Picker("Realm", selection: $model.selectedRealm) {
                        ForEach(model.realms) { realm in
                            Text(realm.comment.map { "\(realm.realm) – \($0)" } ?? realm.realm).tag(realm.realm)
                        }
                    }
                }
            }
        } header: {
            Text("Account")
        } footer: {
            switch model.proxmoxAuth {
            case .password:
                Text("A user with two-factor authentication (TOTP) is asked for the code at every sign-in; the app cannot refresh such a server in the background. Prefer an API token for that.")
            case .apiToken:
                Text("Create the token under Datacenter → Permissions → API Tokens. Turn off “Privilege Separation” so the token has the user’s permissions, or give the token its own. The secret is shown by Proxmox only once; it is stored in this device’s Keychain.")
            case .openID:
                Text("The sign-in opens your identity provider in a browser sheet (passkeys work there). Register \(OpenIDRedirect.url) as an allowed redirect URI for the Proxmox client in your identity provider. Afterwards the app can create an API token for this user, so later sign-ins and background refresh need no browser.")
            }
        }
    }
}

private struct FinishedView: View {
    let serverName: String
    let hint: AccountHint
    let isFinishing: Bool
    @Binding var createsAPIToken: Bool
    let errorMessage: String?
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .padding(.top, 24)
                Text("Connected to \(serverName)")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                if hint.offersAPIToken {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $createsAPIToken) {
                            Label("Create API token for automatic sign-in", systemImage: "key.fill")
                                .font(.headline)
                        }
                        Text("The browser sign-in lasts two hours. With a token in this device’s Keychain the app signs in by itself afterwards and can refresh in the background. The token is created for your own account without privilege separation; you can revoke it any time under Datacenter → Permissions → API Tokens.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.1), in: .rect(cornerRadius: 16))
                }

                if !hint.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Recommendation", systemImage: "lightbulb")
                            .font(.headline)
                        if hint.usesBuiltInAdmin {
                            if hint.kind == .proxmox {
                                Text("You signed in as root@pam. Consider a dedicated user (Datacenter → Permissions → Users) with an API token for this app, so root stays out of the Keychain of a phone.")
                            } else {
                                Text("You signed in with the built-in “admin” account. It is the first target of attacks. Create a separate account in the “administrators” group for this app (Control Panel → User & Group) and disable “admin”.")
                            }
                        }
                        if hint.lacksTwoFactor {
                            if hint.kind == .proxmox {
                                Text("This account has no two-factor authentication. Turn it on in Proxmox (Datacenter → Permissions → Two Factor), or use an API token for this app and keep the password for the web UI only.")
                            } else {
                                Text("This account has no two-factor authentication. Turn it on in DSM (Personal → Security → 2-Factor Authentication). The app asks for the code only once and then remembers this device.")
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onDone) {
                    Group {
                        if isFinishing { ProgressView() } else { Text("Done") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFinishing)
                .controlSize(.large)
            }
            .padding()
        }
    }
}

/// Row of coloured circles. A menu `Picker` renders its icons monochrome, so the colours were invisible.
struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                ForEach(Palette.tintNames, id: \.self) { name in
                    Button {
                        selection = name
                    } label: {
                        Circle()
                            .fill(Palette.tint(name))
                            .frame(width: 26, height: 26)
                            .overlay {
                                if selection == name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(3)
                            .overlay {
                                Circle().strokeBorder(selection == name ? Palette.tint(name) : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(name.capitalized))
                    .accessibilityAddTraits(selection == name ? .isSelected : [])
                }
            }
        }
    }
}
