import Foundation
import Domain

public enum ProbeOutcome: Sendable, Equatable {
    /// TLS handshake succeeded (system trust or matching pin) and the server answered.
    case reachable
    /// No pin yet and the system does not trust the certificate.
    case untrusted(CertificateInfo)
    /// A pin exists and this address presented a different key (e.g. a foreign device in a hotel Wi-Fi).
    case mismatch(CertificateInfo)
    case unreachable
}

public enum AddressResolution: Sendable, Equatable {
    case selected(ServerAddress)
    case needsTrust(ServerAddress, CertificateInfo)
    /// No address matched and at least one presented a foreign fingerprint.
    case fingerprintChanged(observed: CertificateInfo)
    case unreachable
}

/// Picks the address to use: last reached first, then the configured order.
/// Credentials are only sent after this returned `.selected`.
public struct AddressResolver: Sendable {
    public typealias Probe = @Sendable (ServerAddress) async -> ProbeOutcome

    private let probe: Probe

    public init(probe: @escaping Probe) {
        self.probe = probe
    }

    public static func orderedAddresses(_ addresses: [ServerAddress], lastReachedID: UUID?) -> [ServerAddress] {
        guard let lastReachedID, let index = addresses.firstIndex(where: { $0.id == lastReachedID }) else {
            return addresses
        }
        var ordered = addresses
        let last = ordered.remove(at: index)
        ordered.insert(last, at: 0)
        return ordered
    }

    public func resolve(_ addresses: [ServerAddress], lastReachedID: UUID?) async -> AddressResolution {
        var firstUntrusted: (ServerAddress, CertificateInfo)?
        var firstMismatch: CertificateInfo?

        for address in Self.orderedAddresses(addresses, lastReachedID: lastReachedID) {
            if Task.isCancelled { return .unreachable }
            switch await probe(address) {
            case .reachable:
                return .selected(address)
            case .untrusted(let info):
                if firstUntrusted == nil { firstUntrusted = (address, info) }
            case .mismatch(let info):
                if firstMismatch == nil { firstMismatch = info }
            case .unreachable:
                continue
            }
        }

        if let firstMismatch { return .fingerprintChanged(observed: firstMismatch) }
        if let (address, info) = firstUntrusted { return .needsTrust(address, info) }
        return .unreachable
    }
}
