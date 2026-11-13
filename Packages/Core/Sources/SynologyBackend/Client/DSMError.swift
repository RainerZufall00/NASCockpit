import Foundation
import Domain
import Networking

/// DSM-internal errors. Translated into `BackendError` before leaving the adapter.
enum DSMError: Error, Equatable, Sendable {
    case api(code: Int)
    /// 106 (timeout) / 119 (SID not found) → exactly one re-login.
    case sessionExpired
    /// 107 → session ended by a duplicate login: re-login and tell the user.
    case sessionInterrupted
    /// 105 → hide the action, do not re-login.
    case permissionDenied
    /// API missing (package not installed, version not supported).
    case unsupported(String)
    case notConnected
    case invalidAddress
    case invalidResponse
    case decoding(api: String, description: String)
    case transport(TransportError)
    case auth(BackendError)

    var isSessionError: Bool {
        self == .sessionExpired || self == .sessionInterrupted
    }

    /// Short technical description for error details, e.g. "SYNO.Core.Package.Installation #103".
    var diagnostic: String {
        switch self {
        case .unsupported(let detail): detail
        case .api(let code): "DSM error \(code)"
        case .decoding(let api, _): "unexpected answer from \(api)"
        default: String(describing: self)
        }
    }

    /// Adds the method to a "not available" error so the details say which step DSM rejected.
    func labelled(_ method: String) -> DSMError {
        switch self {
        case .unsupported(let detail): .unsupported("\(detail) in \(method)")
        case .api(let code): .unsupported("DSM error \(code) in \(method)")
        default: self
        }
    }

    var isConnectivityError: Bool {
        switch self {
        case .transport(.unreachable), .transport(.timeout): true
        default: false
        }
    }

    /// Common codes (100–119) are handled centrally, login codes (400–410) only for SYNO.API.Auth.
    static func from(code: Int, api: String) -> DSMError {
        switch code {
        case 105: return .permissionDenied
        case 106, 119: return .sessionExpired
        case 107: return .sessionInterrupted
        // The code stays in the text for diagnostics: 102 API missing, 103 method missing, 104 version not supported.
        case 102, 103, 104: return .unsupported("\(api) #\(code)")
        default: break
        }
        if api == DSMEndpoints.Auth.api {
            switch code {
            case 400: return .auth(.invalidCredentials)
            case 401: return .auth(.accountDisabled)
            case 402: return .auth(.permissionDenied)
            case 403: return .auth(.otpRequired)
            case 404: return .auth(.otpInvalid)
            case 406: return .auth(.twoFactorSetupRequired)
            case 407: return .auth(.ipBlocked)
            case 408, 409, 410: return .auth(.passwordExpired)
            default: break
            }
        }
        return .api(code: code)
    }

    static func backendError(from error: any Error) -> BackendError {
        if let error = error as? BackendError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? DSMError else { return BackendError(error) }
        switch error {
        case .auth(let backendError): return backendError
        case .permissionDenied: return .actionNotPermitted
        case .sessionExpired, .sessionInterrupted: return .sessionLost
        case .unsupported: return .notSupported
        case .notConnected: return .notConnected
        case .invalidAddress: return .invalidAddress
        case .invalidResponse, .decoding: return .invalidResponse
        case .api(let code): return .server(code: code)
        case .transport(let transportError):
            switch transportError {
            case .untrustedCertificate(let info): return .certificateUntrusted(info)
            case .fingerprintMismatch(let info): return .fingerprintChanged(expected: "", observed: info)
            case .timeout: return .timeout
            case .cancelled: return .cancelled
            case .invalidRequest: return .invalidAddress
            case .invalidResponse, .httpStatus: return .invalidResponse
            case .unreachable: return .unreachable
            }
        }
    }
}
