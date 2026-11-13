import Foundation

/// `{"success": Bool, "error": {"code": Int}}` – decoded first, so an error response
/// whose `data` has a different shape never masks the error code.
struct DSMStatus: Decodable, Sendable {
    struct ErrorPayload: Decodable, Sendable {
        let code: Int
    }

    let success: Bool
    let error: ErrorPayload?
}

struct DSMDataEnvelope<T: Decodable>: Decodable {
    let data: T
}

/// For calls without a meaningful payload (logout, actions).
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}

enum DSMDecoding {
    /// Decodes a DSM response. Throws `DSMError` for `success == false`.
    static func decode<R: Decodable>(_ data: Data, api: String, as type: R.Type = R.self) throws -> R {
        let decoder = JSONDecoder()
        let status: DSMStatus
        do {
            status = try decoder.decode(DSMStatus.self, from: data)
        } catch {
            throw DSMError.invalidResponse
        }
        guard status.success else {
            throw DSMError.from(code: status.error?.code ?? 100, api: api)
        }
        if let empty = EmptyResponse() as? R { return empty }
        do {
            return try decoder.decode(DSMDataEnvelope<R>.self, from: data).data
        } catch {
            throw DSMError.decoding(api: api, description: String(describing: error))
        }
    }
}
