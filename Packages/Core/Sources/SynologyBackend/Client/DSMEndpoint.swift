import Foundation

/// A typed DSM call. Feature code never sees raw endpoints; it calls typed backend methods.
struct DSMEndpoint<Response: Decodable & Sendable>: Sendable {
    enum Documentation: Sendable {
        /// Documented by Synology (Auth, File Station).
        case official
        /// Observed in the DSM web UI / open-source libraries. Verify against real DSM.
        case undocumented
    }

    let api: String
    let method: String
    /// Versions the app understands. The client picks the highest one the NAS supports.
    let versions: ClosedRange<Int>
    var params: [String: String] = [:]
    /// Writes are sent as POST and are never retried automatically after a connection drop.
    var isWrite: Bool = false
    var documentation: Documentation = .undocumented
    var timeout: TimeInterval = 10
}

/// One entry of a `SYNO.Entry.Request` compound call.
struct CompoundItem: Sendable {
    let api: String
    let method: String
    let versions: ClosedRange<Int>
    let params: [String: String]

    init<R>(_ endpoint: DSMEndpoint<R>) {
        api = endpoint.api
        method = endpoint.method
        versions = endpoint.versions
        params = endpoint.params
    }
}

struct CompoundResponse: Decodable, Sendable {
    let result: [CompoundResult]

    private enum CodingKeys: String, CodingKey { case result }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = container.lossyArray(CompoundResult.self, .result)
    }
}

struct CompoundResult: Decodable, Sendable {
    let api: String
    let method: String?
    let success: Bool
    let data: JSONValue?
    let error: DSMStatus.ErrorPayload?

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard success, let data else { return nil }
        return try? data.decode(as: T.self)
    }
}
