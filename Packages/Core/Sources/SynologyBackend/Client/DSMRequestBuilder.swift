import Foundation
import Domain

struct DSMSession: Sendable, Equatable {
    let sid: String
    let synoToken: String?
}

/// Builds `https://<host>:<port>/webapi/<path>` requests (`http://` only for private hosts).
/// Reads are GET, writes POST (`application/x-www-form-urlencoded`).
enum DSMRequestBuilder {
    /// RFC 3986 unreserved characters. Everything else is percent-encoded, including `+`,
    /// which DSM would otherwise decode as a space.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func request(
        address: ServerAddress,
        path: String,
        params: [String: String],
        isWrite: Bool,
        timeout: TimeInterval,
        session: DSMSession?
    ) throws -> URLRequest {
        // HTTP only for hosts in the local network / VPN; a public host is refused instead of downgraded.
        guard address.usesHTTPS || address.allowsPlainHTTP else { throw DSMError.invalidAddress }
        let scheme = address.usesHTTPS ? "https" : "http"
        guard address.port > 0, address.port < 65536, !address.urlHost.isEmpty,
              let url = URL(string: "\(scheme)://\(address.urlHost):\(address.port)/webapi/\(path)")
        else { throw DSMError.invalidAddress }

        var all = params
        if let session { all["_sid"] = session.sid }
        let encoded = formEncode(all)

        var request: URLRequest
        if isWrite {
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(encoded.utf8)
        } else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DSMError.invalidAddress }
            components.percentEncodedQuery = encoded
            guard let queryURL = components.url else { throw DSMError.invalidAddress }
            request = URLRequest(url: queryURL)
            request.httpMethod = "GET"
        }
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = session?.synoToken {
            request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return request
    }

    static func formEncode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Parses parameters back out of a request (used by tests and mock transports).
    static func parameters(of request: URLRequest) -> [String: String] {
        let query: String?
        if request.httpMethod == "POST", let body = request.httpBody {
            query = String(decoding: body, as: UTF8.self)
        } else {
            query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
        }
        var result: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            result[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        }
        return result
    }
}
