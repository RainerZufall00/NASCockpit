import Foundation

/// Finds the same NAS added separately on two devices: same backend, same user and at least one
/// shared address. The profile with the smallest UUID survives, so every device decides the same way.
public enum ProfileDeduplication {
    public static func merges(_ profiles: [ServerProfile]) -> [(removed: ServerID, kept: ServerID)] {
        let sorted = profiles.sorted { $0.id.uuidString < $1.id.uuidString }
        var kept: [ServerProfile] = []
        var result: [(removed: ServerID, kept: ServerID)] = []
        for profile in sorted {
            if let survivor = kept.first(where: { isSameServer($0, profile) }) {
                if survivor.id != profile.id { result.append((removed: profile.id, kept: survivor.id)) }
            } else {
                kept.append(profile)
            }
        }
        return result
    }

    public static func isSameServer(_ a: ServerProfile, _ b: ServerProfile) -> Bool {
        guard a.backend == b.backend, a.username.lowercased() == b.username.lowercased() else { return false }
        return !Set(a.addresses.map(endpoint)).isDisjoint(with: b.addresses.map(endpoint))
    }

    /// The survivor's addresses first, then the ones only the other copy knew.
    public static func union(_ first: [ServerAddress], _ second: [ServerAddress]) -> [ServerAddress] {
        let known = Set(first.map(endpoint))
        return first + second.filter { !known.contains(endpoint($0)) }
    }

    private static func endpoint(_ address: ServerAddress) -> String {
        "\(address.host.lowercased()):\(address.port)"
    }
}

extension ServerProfile {
    /// Changes that need a new connection. Name, colour, notifications and the like do not.
    public func connectionDetailsDiffer(from other: ServerProfile) -> Bool {
        addresses != other.addresses || backend != other.backend || authMethod != other.authMethod
            || username != other.username || pinnedSPKI != other.pinnedSPKI || savesPassword != other.savesPassword
            || trustedCertificateName != other.trustedCertificateName
    }
}
