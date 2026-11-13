import Foundation
import Domain
import Networking

/// How a request proves who it is.
enum PVEAuth: Sendable, Equatable {
    /// Ticket from `/access/ticket` (password or OpenID). Valid for two hours; the connection renews it.
    case ticket(String, csrf: String, issued: Date)
    /// `user@realm!name=secret`. Never expires, no CSRF token needed.
    case token(String)

    var isTicket: Bool {
        if case .ticket = self { return true }
        return false
    }
}

enum PVEMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"

    var isWrite: Bool { self != .get }
}

/// A typed Proxmox call: `METHOD /api2/json/<path>`.
struct PVEEndpoint<Response: Decodable & Sendable>: Sendable {
    let method: PVEMethod
    /// Without the `/api2/json/` prefix, e.g. `nodes/pve/status`.
    let path: String
    var params: [String: String] = [:]
    var timeout: TimeInterval = 15

    init(_ method: PVEMethod, _ path: String, params: [String: String] = [:], timeout: TimeInterval = 15) {
        self.method = method
        self.path = path
        self.params = params
        self.timeout = timeout
    }
}

/// Proxmox-internal errors. Translated into `BackendError` before leaving the adapter.
enum PVEError: Error, Equatable, Sendable {
    /// HTTP error status with the message Proxmox put into the body (or the status line).
    case http(status: Int, message: String)
    /// 401 outside the login: the ticket expired or was rejected → exactly one re-login.
    case sessionExpired
    /// 403 → hide the action, do not re-login.
    case permissionDenied
    /// Password login needs a second step with the TOTP code.
    case needsTFA(challenge: String)
    case notConnected
    case invalidAddress
    case invalidResponse
    case transport(TransportError)
    case auth(BackendError)
    case taskFailed(String)

    var isConnectivityError: Bool {
        switch self {
        case .transport(.unreachable), .transport(.timeout): true
        default: false
        }
    }

    static func backendError(from error: any Error) -> BackendError {
        if let error = error as? BackendError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? PVEError else { return BackendError(error) }
        switch error {
        case .auth(let backendError): return backendError
        case .permissionDenied: return .actionNotPermitted
        case .sessionExpired: return .sessionLost
        case .needsTFA: return .otpRequired
        case .notConnected: return .notConnected
        case .invalidAddress: return .invalidAddress
        case .invalidResponse: return .invalidResponse
        case .taskFailed(let message): return .operationFailed(message)
        case .http(let status, let message):
            return message.isEmpty ? .server(code: status) : .operationFailed(message)
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

/// Builds `https://<host>:<port>/api2/json/<path>` requests. Proxmox only speaks HTTPS.
/// Reads are GET with a query string, writes carry a form body.
enum PVERequestBuilder {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func request(address: ServerAddress, method: PVEMethod, path: String, params: [String: String], auth: PVEAuth?, timeout: TimeInterval) throws -> URLRequest {
        guard address.usesHTTPS else { throw PVEError.invalidAddress }
        guard address.port > 0, address.port < 65536, !address.urlHost.isEmpty,
              let url = URL(string: "https://\(address.urlHost):\(address.port)/api2/json/\(path)")
        else { throw PVEError.invalidAddress }

        var request: URLRequest
        let encoded = formEncode(params)
        if method.isWrite {
            request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(encoded.utf8)
        } else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PVEError.invalidAddress }
            if !encoded.isEmpty { components.percentEncodedQuery = encoded }
            guard let queryURL = components.url else { throw PVEError.invalidAddress }
            request = URLRequest(url: queryURL)
            request.httpMethod = method.rawValue
        }
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .ticket(let ticket, let csrf, _):
            request.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
            if method.isWrite { request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken") }
        case .token(let token):
            request.setValue("PVEAPIToken=\(token)", forHTTPHeaderField: "Authorization")
        case nil:
            break
        }
        return request
    }

    static func formEncode(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Parses parameters back out of a request (tests and fakes).
    static func parameters(of request: URLRequest) -> [String: String] {
        let query: String?
        if request.httpMethod != "GET", let body = request.httpBody {
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

/// `{"data": …}` plus, on errors, `"message"` and `"errors"`. Lists add `"total"`.
struct PVEEnvelope<T: Decodable>: Decodable {
    let data: T?
    let message: String?
    let total: Int?
}

/// Proxmox is inconsistent about scalar types (0/1 ints, "N/A" strings, numbers as strings).
/// Any JSON value Proxmox sends in loosely typed objects. Nested objects appear where the API parses a
/// property string for the reader, e.g. `prune-backups`, `performance` and `fleecing` of backup jobs.
indirect enum PVEScalar: Decodable, Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: PVEScalar])
    case array([PVEScalar])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: PVEScalar].self) { self = .object(value); return }
        self = .array(try container.decode([PVEScalar].self))
    }

    /// Objects become a property string again ("keep-daily=7,keep-weekly=4", keys sorted),
    /// which is what POST/PUT parameters expect.
    var stringValue: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value == value.rounded() ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "1" : "0"
        case .object(let values): values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.stringValue)" }.joined(separator: ",")
        case .array(let values): values.map(\.stringValue).joined(separator: ",")
        case .null: ""
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string(let value): ["1", "true", "yes", "on"].contains(value.lowercased())
        case .object, .array, .null: false
        }
    }

    var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value): Int64(value)
        case .bool(let value): value ? 1 : 0
        case .string(let value): Int64(value) ?? Double(value).map { Int64($0) }
        case .object, .array, .null: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .bool(let value): value ? 1 : 0
        case .string(let value): Double(value)
        case .object, .array, .null: nil
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: true
        case .object(let values): values.isEmpty
        case .array(let values): values.isEmpty
        default: false
        }
    }
}

enum PVEDecoding {
    /// Decodes a successful response body. The connection has already turned error statuses into errors.
    static func decode<R: Decodable>(_ data: Data, as type: R.Type = R.self) throws -> (value: R, total: Int?) {
        let decoder = JSONDecoder()
        do {
            let envelope = try decoder.decode(PVEEnvelope<R>.self, from: data)
            if let value = envelope.data { return (value, envelope.total) }
            if let empty = PVEEmpty() as? R { return (empty, envelope.total) }
            throw PVEError.invalidResponse
        } catch let error as PVEError {
            throw error
        } catch {
            throw PVEError.invalidResponse
        }
    }

    /// The `message` of an error response, if the body is JSON.
    static func errorMessage(_ data: Data) -> String? {
        struct Body: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// For calls whose `data` is `null` or irrelevant.
struct PVEEmpty: Decodable, Sendable, Equatable {
    init() {}
    init(from decoder: any Decoder) throws {}
}

/// A task identifier (`UPID:node:…`) returned by every long-running call.
struct PVEUPID: Decodable, Sendable, Equatable {
    let value: String

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    init(_ value: String) { self.value = value }

    /// The node that runs the task, from `UPID:<node>:…`.
    var node: String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : nil
    }
}
