import Foundation

/// Result of `SYNO.API.Info` / `query` with `query=all`, cached per connection until the next login.
struct APICatalog: Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable {
        let path: String
        let minVersion: Int
        let maxVersion: Int
    }

    let entries: [String: Entry]

    func supports(_ api: String) -> Bool {
        entries[api] != nil
    }

    /// Picks the highest version both the app and the NAS support.
    func resolve(api: String, versions: ClosedRange<Int>) throws -> (path: String, version: Int) {
        guard let entry = entries[api] else { throw DSMError.unsupported(api) }
        let upper = min(versions.upperBound, entry.maxVersion)
        let lower = max(versions.lowerBound, entry.minVersion)
        guard lower <= upper else { throw DSMError.unsupported(api) }
        return (entry.path, upper)
    }
}
