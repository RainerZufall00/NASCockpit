import Foundation
import Domain

/// URLSession-based transport for one NAS: ephemeral (own cookie storage, no cache),
/// HTTPS with the certificate decision by `PinningDelegate`; HTTP only for private hosts.
public final class PinnedTransport: HTTPTransport {
    private let delegate: PinningDelegate
    private let session: URLSession

    public init(pinnedSPKI: String?, requestTimeout: TimeInterval = 10) {
        delegate = PinningDelegate(pinnedSPKI: pinnedSPKI)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "NASCockpit"]
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func updatePinnedSPKI(_ spki: String?) {
        delegate.updatePin(spki)
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> Data {
        let response = try await fetch(request)
        guard response.isSuccess else { throw TransportError.httpStatus(response.status) }
        return response.body
    }

    public func fetch(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), let host = url.host() else {
            throw TransportError.invalidRequest
        }
        // Defense in depth: plain HTTP never leaves the local network / VPN.
        guard scheme == "https" || (scheme == "http" && ServerAddress.isPrivateNetworkHost(host)) else {
            throw TransportError.invalidRequest
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
            return HTTPResponse(status: http.statusCode, body: data)
        } catch let error as TransportError {
            throw error
        } catch {
            switch delegate.observation(host: host, port: port) {
            case .untrusted(let info): throw TransportError.untrustedCertificate(info)
            case .mismatch(let info): throw TransportError.fingerprintMismatch(observed: info)
            case .unsupportedKey: throw TransportError.unreachable
            case .trusted, .none: throw Self.map(error)
            }
        }
    }

    static func map(_ error: any Error) -> TransportError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        default: return .unreachable
        }
    }
}
