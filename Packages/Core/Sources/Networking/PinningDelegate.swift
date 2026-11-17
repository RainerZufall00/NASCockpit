import Foundation
import Security
import Synchronization
import Domain

/// Per-server TLS decision. ATS stays on; the only exceptions for certificates the
/// system does not trust happen here:
/// - the SPKI pinned for this NAS, or
/// - a certificate that a public CA issued for the name the user trusted (`trustedName`). That covers a NAS
///   reached by IP address whose Let's Encrypt certificate is renewed with a new key every few months. Only the
///   owner of that domain can get such a certificate, so this is as strict as the pin.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    enum Observation: Sendable, Equatable {
        case trusted
        case untrusted(CertificateInfo)
        case mismatch(CertificateInfo)
        case unsupportedKey
    }

    private struct Pin {
        var spki: String?
        var name: String?
    }

    private let pin: Mutex<Pin>
    private let observations = Mutex<[String: Observation]>([:])

    init(pinnedSPKI: String?, trustedName: String? = nil) {
        pin = Mutex(Pin(spki: pinnedSPKI, name: trustedName))
    }

    func updatePin(spki: String?, trustedName: String?) {
        pin.withLock { $0 = Pin(spki: spki, name: trustedName) }
        observations.withLock { $0.removeAll() }
    }

    func observation(host: String, port: Int) -> Observation? {
        let key = Self.key(host: host, port: port)
        return observations.withLock { $0[key] }
    }

    static func key(host: String, port: Int) -> String {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return "\(bare):\(port)"
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let observation = evaluate(trust)
        let key = Self.key(host: space.host, port: space.port)
        observations.withLock { $0[key] = observation }
        if observation == .trusted {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func evaluate(_ trust: SecTrust) -> Observation {
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        if systemTrusted { return .trusted }
        guard let info = CertificateFingerprint.info(for: trust) else { return .unsupportedKey }
        let pin = pin.withLock { $0 }
        if let name = pin.name, let publicName = info.publicName,
           publicName.caseInsensitiveCompare(name) == .orderedSame {
            return .trusted
        }
        guard let spki = pin.spki else { return .untrusted(info) }
        return spki == info.spkiSHA256 ? .trusted : .mismatch(info)
    }
}
