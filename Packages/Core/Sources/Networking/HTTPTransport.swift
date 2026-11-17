import Foundation
import Domain

public enum TransportError: Error, Sendable, Hashable {
    /// No pin yet and the system does not trust the certificate → ask the user (TOFU).
    case untrustedCertificate(CertificateInfo)
    /// A pin exists and the server presented a different public key.
    case fingerprintMismatch(observed: CertificateInfo)
    case timeout
    case unreachable
    case cancelled
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
}

/// Status code and body of any HTTP response, including error responses.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Sends HTTPS requests for exactly one server. Abstracted so the connection logic
/// can be tested without a network, and so a WebSocket transport (TrueNAS) can be added later.
public protocol HTTPTransport: Sendable {
    /// Returns the body of a 2xx response or throws `TransportError`.
    func send(_ request: URLRequest) async throws -> Data
    /// Returns status and body of any HTTP response; throws `TransportError` only when no response arrived.
    /// Backends whose error details live in the body of a 4xx/5xx response (Proxmox) use this.
    func fetch(_ request: URLRequest) async throws -> HTTPResponse
    /// The key the user trusted and, for a publicly trusted certificate, its name (see `PinningDelegate`).
    func updatePin(spki: String?, trustedName: String?)
    func invalidate()
}

extension HTTPTransport {
    public func fetch(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, body: try await send(request))
    }
}
