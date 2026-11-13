import Foundation
import Security
import Synchronization
import Domain

/// Per-server TLS decision. ATS stays on; the only exception for certificates the
/// system does not trust happens here, and only for the SPKI pinned for this NAS.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    enum Observation: Sendable, Equatable {
        case trusted
        case untrusted(CertificateInfo)
        case mismatch(CertificateInfo)
        case unsupportedKey
    }

    private let pinnedSPKI: Mutex<String?>
    private let observations = Mutex<[String: Observation]>([:])

    init(pinnedSPKI: String?) {
        self.pinnedSPKI = Mutex(pinnedSPKI)
    }

    func updatePin(_ spki: String?) {
        pinnedSPKI.withLock { $0 = spki }
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
        let pin = pinnedSPKI.withLock { $0 }
        guard let pin else { return .untrusted(info) }
        return pin == info.spkiSHA256 ? .trusted : .mismatch(info)
    }
}
