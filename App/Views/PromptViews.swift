import SwiftUI
import Domain
import DesignSystem
import SecurityKit

/// Sheet for prompts raised by the ConnectionManager (OTP, certificate, password).
struct PromptView: View {
    let manager: ConnectionManager
    let prompt: ConnectionPrompt

    @State private var code = ""

    var body: some View {
        NavigationStack {
            Group {
                switch prompt {
                case .otp(let id):
                    OTPEntryView(serverName: name(id), code: $code, errorMessage: nil, kind: manager.profile(id)?.backend ?? .synology,
                                 iconName: manager.profile(id)?.iconName, colorName: manager.profile(id)?.colorName) {
                        let value = code.filter(\.isNumber)
                        Task { await manager.submitOTP(value, for: id) }
                    }
                case .trust(let id, let info, let previous):
                    CertificateTrustView(serverName: name(id), certificate: info, previousSPKI: previous) {
                        Task {
                            // Accepting a *changed* key is security relevant: always confirm with Face ID.
                            if previous != nil {
                                guard await BiometricGate.confirm(reason: String(localized: "Trust the new certificate of \(name(id))")) else { return }
                            }
                            await manager.trust(info, for: id)
                        }
                    } onCancel: {
                        manager.dismissPrompt(prompt)
                    }
                case .password(let id):
                    if let profile = manager.profile(id) {
                        PasswordEntryView(profile: profile) { password in
                            Task { await manager.signIn(id, password: password) }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { manager.dismissPrompt(prompt) }
                }
            }
        }
    }

    private func name(_ id: ServerID) -> String {
        manager.profile(id)?.name ?? ""
    }
}

/// Shared look of the sign-in prompts: the server's icon and name on top, the field, one big button.
private struct SignInCard<Field: View>: View {
    let iconName: String
    let colorName: String
    let title: String
    let subtitle: String
    let message: String
    var errorMessage: String?
    let buttonTitle: LocalizedStringKey
    let buttonImage: String
    let canSubmit: Bool
    let onSubmit: () -> Void
    @ViewBuilder let field: Field

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    ServerIcon(systemName: iconName, colorName: colorName, size: 72)
                        .shadow(color: Palette.tint(colorName).opacity(0.35), radius: 12, y: 6)
                    VStack(spacing: 4) {
                        Text(title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, 8)

                field

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onSubmit) {
                    Label(buttonTitle, systemImage: buttonImage)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct PasswordEntryView: View {
    let profile: ServerProfile
    let onSubmit: (String) -> Void

    @State private var password = ""
    @State private var isRevealed = false
    @FocusState private var focused: Bool

    var body: some View {
        SignInCard(
            iconName: profile.iconName,
            colorName: profile.colorName,
            title: profile.name,
            subtitle: subtitle,
            message: message,
            buttonTitle: "Sign In",
            buttonImage: "arrow.right.circle.fill",
            canSubmit: !password.isEmpty,
            onSubmit: submit
        ) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Group {
                    if isRevealed {
                        TextField(profile.authMethod == .apiToken ? "API Token Secret" : "Password", text: $password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField(profile.authMethod == .apiToken ? "API Token Secret" : "Password", text: $password)
                    }
                }
                .textContentType(.password)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
                Button {
                    isRevealed.toggle()
                    focused = true
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "Hide Password" : "Show Password")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        }
        .onAppear { focused = true }
    }

    private var subtitle: String {
        let host = profile.addresses.first?.host ?? ""
        guard !profile.username.isEmpty else { return host }
        return host.isEmpty ? profile.username : "\(profile.username) @ \(host)"
    }

    private var message: String {
        profile.savesPassword
            ? String(localized: "Saved in this device's Keychain, protected by \(BiometricGate.biometryName). It never leaves this device.")
            : String(localized: "Kept in memory until the app ends.")
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
    }
}

struct OTPEntryView: View {
    let serverName: String
    @Binding var code: String
    let errorMessage: String?
    var kind: BackendKind = .synology
    var iconName: String?
    var colorName: String?
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    private let length = 6

    var body: some View {
        SignInCard(
            iconName: iconName ?? "lock.shield.fill",
            colorName: colorName ?? "blue",
            title: String(localized: "Two-Factor Code"),
            subtitle: serverName,
            message: kind == .proxmox
                ? String(localized: "Enter the code from your authenticator app. Proxmox asks for it at every sign-in; use an API token if you want to avoid that.")
                : String(localized: "Enter the code from your authenticator app. This device will be remembered, so the code is only needed once."),
            errorMessage: errorMessage,
            buttonTitle: "Verify",
            buttonImage: "checkmark.shield.fill",
            canSubmit: digits.count == length,
            onSubmit: submit
        ) {
            ZStack {
                // The real field: invisible, takes the keyboard and the code from Messages / Passwords.
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .onChange(of: code) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(length))
                        if filtered != newValue { code = filtered }
                        if filtered.count == length { submit() }
                    }
                    .accessibilityLabel("6-digit code")

                HStack(spacing: 8) {
                    ForEach(0..<length, id: \.self) { index in
                        digitBox(index)
                        if index == 2 {
                            Capsule().fill(.tertiary).frame(width: 10, height: 3)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(.rect)
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
    }

    private var digits: [Character] { Array(code.filter(\.isNumber).prefix(length)) }

    private func digitBox(_ index: Int) -> some View {
        let isCurrent = focused && index == min(digits.count, length - 1)
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.title.monospacedDigit().weight(.semibold))
            .frame(maxWidth: 48)
            .frame(height: 58)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isCurrent ? Color.accentColor : errorMessage != nil ? .red.opacity(0.6) : .clear, lineWidth: 2)
            }
            .animation(.snappy(duration: 0.15), value: digits.count)
    }

    private func submit() {
        guard digits.count == length else { return }
        onSubmit()
    }
}

/// TOFU confirmation. Shows the SPKI fingerprint that will be pinned and, if it changed, the old one.
struct CertificateTrustView: View {
    let serverName: String
    let certificate: CertificateInfo
    let previousSPKI: String?
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section {
                if previousSPKI != nil {
                    Label("The certificate of \(serverName) has changed", systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("This can be a renewed certificate – or someone intercepting the connection. Only continue if you changed the certificate on the NAS yourself. Compare the fingerprint with DSM (Control Panel → Security → Certificate).")
                } else {
                    Label("Confirm the certificate of \(serverName)", systemImage: "lock.shield")
                        .font(.headline)
                    Text("The NAS uses a certificate that iOS does not trust automatically (e.g. self-signed, or accessed via IP address). Check that the fingerprint matches the certificate in DSM. NAS Cockpit will remember this key and block the connection if it ever changes.")
                }
            }
            .font(.subheadline)

            Section("Certificate") {
                LabeledContent("Subject", value: certificate.subject.isEmpty ? "–" : certificate.subject)
                fingerprint("Public key (SPKI) SHA-256", certificate.spkiSHA256)
                fingerprint("Certificate SHA-256", certificate.certificateSHA256)
            }

            if let previousSPKI, !previousSPKI.isEmpty {
                Section("Previously trusted key") {
                    fingerprint("Public key (SPKI) SHA-256", previousSPKI)
                }
            }

            Section {
                Button(previousSPKI == nil ? "Trust and Connect" : "Trust New Certificate", role: previousSPKI == nil ? nil : .destructive, action: onTrust)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
    }

    private func fingerprint(_ title: LocalizedStringKey, _ hex: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(CertificateInfo.grouped(hex))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
