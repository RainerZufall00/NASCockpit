import Foundation

/// What the user sees when a certificate is not trusted by the system (TOFU) or changed.
public struct CertificateInfo: Hashable, Codable, Sendable {
    /// SHA-256 of the SubjectPublicKeyInfo, hex lowercase. This is what gets pinned.
    public let spkiSHA256: String
    /// SHA-256 of the full certificate, for comparing with browsers / DSM.
    public let certificateSHA256: String
    public let subject: String
    /// Host name this certificate is valid for according to a public certificate authority (e.g. Let's Encrypt),
    /// although the connection used another name or an IP address. `nil` for self-signed certificates.
    public let publicName: String?

    public init(spkiSHA256: String, certificateSHA256: String, subject: String, publicName: String? = nil) {
        self.spkiSHA256 = spkiSHA256
        self.certificateSHA256 = certificateSHA256
        self.subject = subject
        self.publicName = publicName
    }

    /// "AB:CD:EF:…"
    public static func grouped(_ hex: String) -> String {
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: ":")
    }
}

/// Platform-neutral errors. Adapters translate their own error codes into these.
public enum BackendError: Error, Hashable, Sendable {
    case unreachable
    case timeout
    case cancelled
    case invalidAddress
    case certificateUntrusted(CertificateInfo)
    case fingerprintChanged(expected: String, observed: CertificateInfo)
    case passwordRequired
    /// OpenID profile without an API token: the user has to sign in through the browser.
    case openIDSignInRequired
    case credentialsUnavailable
    case otpRequired
    case otpInvalid
    case invalidCredentials
    case accountDisabled
    case permissionDenied
    case actionNotPermitted
    case ipBlocked
    case twoFactorSetupRequired
    case passwordExpired
    case notConnected
    case notSupported
    case sessionLost
    case invalidResponse
    case rebootTimeout
    /// The backup destination does not answer, so the task cannot run.
    case backupTargetOffline(task: String)
    /// The NAS accepted the start, but the run ended right away without backing up.
    case backupDidNotStart(task: String)
    case operationFailed(String)
    case server(code: Int)
    case other(String)

    public init(_ error: any Error) {
        if let error = error as? BackendError {
            self = error
        } else if error is CancellationError {
            self = .cancelled
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            self = .cancelled
        } else {
            self = .other(error.localizedDescription)
        }
    }

    /// Errors that mean "the credentials are not accepted" – background refresh pauses on these.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .invalidCredentials, .accountDisabled, .permissionDenied, .otpRequired, .otpInvalid,
             .ipBlocked, .twoFactorSetupRequired, .passwordExpired, .passwordRequired, .credentialsUnavailable,
             .openIDSignInRequired:
            true
        default:
            false
        }
    }
}

extension BackendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable: String(localized: "The NAS is not reachable at any of its addresses.")
        case .timeout: String(localized: "The NAS did not respond in time.")
        case .cancelled: String(localized: "The request was cancelled.")
        case .invalidAddress: String(localized: "The address is invalid.")
        case .certificateUntrusted: String(localized: "The certificate of this NAS needs to be confirmed.")
        case .fingerprintChanged: String(localized: "The certificate fingerprint of this NAS has changed. The connection was blocked.")
        case .passwordRequired: String(localized: "Please sign in with your password.")
        case .openIDSignInRequired: String(localized: "Please sign in through your identity provider.")
        case .credentialsUnavailable: String(localized: "The saved credentials could not be unlocked.")
        case .otpRequired: String(localized: "A two-factor code is required.")
        case .otpInvalid: String(localized: "The two-factor code is incorrect.")
        case .invalidCredentials: String(localized: "Unknown account or wrong password.")
        case .accountDisabled: String(localized: "This account is disabled.")
        case .permissionDenied: String(localized: "This account is not allowed to sign in. Use an account in the “administrators” group.")
        case .actionNotPermitted: String(localized: "This account is not permitted to perform this action.")
        case .ipBlocked: String(localized: "This device’s IP address has been blocked by the NAS (Auto Block). All retries were stopped. Unblock the IP in DSM and try again.")
        case .twoFactorSetupRequired: String(localized: "The NAS requires two-factor authentication to be set up for this account. Set it up in DSM first.")
        case .passwordExpired: String(localized: "The password of this account has expired. Change it in DSM first.")
        case .notConnected: String(localized: "Not connected.")
        case .notSupported: String(localized: "This feature is not available on this NAS.")
        case .sessionLost: String(localized: "The session ended and could not be restored.")
        case .invalidResponse: String(localized: "The NAS sent a response the app does not understand.")
        case .rebootTimeout: String(localized: "The NAS did not come back after the restart. Check it in the DSM web interface or on the device.")
        case .backupTargetOffline(let task): String(localized: "The destination of “\(task)” is offline. Switch it on or check the connection to it, then try again.")
        case .backupDidNotStart(let task): String(localized: "“\(task)” did not start. The backup ended right away; the backup log on the NAS shows why.")
        case .operationFailed(let message): message
        // String(code): no thousands separator ("5017", not "5.017").
        case .server(let code): String(localized: "The NAS reported error \(String(code)).")
        case .other(let message): message
        }
    }
}
