import Foundation
import Security
import Testing
@testable import Networking

/// Expected values computed with:
/// `openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der | shasum -a 256`
@Suite("SPKI fingerprints")
struct CertificateFingerprintTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let file: String
        let spki: String
        let certificate: String
        var testDescription: String { file }
    }

    static let cases: [Case] = [
        Case(file: "rsa", spki: "a09068ec3230c3e4ab63cec1dcec44221cd930e6c476caa1fea61b1d7cde9dc3", certificate: "0e721c28a5ded487c3a84828ad07434c39992fa018e73f3b1eb7e0902668ce20"),
        Case(file: "ec", spki: "188bf6de36681badcc2722ea1e07629f4ad628439a122dc9bd221c5c0a7c1e42", certificate: "b2e5362a3c0153babee96edf21befd1342c255907d0c240bc4a3a6ddfe877c75"),
        Case(file: "ec384", spki: "5365144cd2094c551209a56579b03a1ca0aabb68a18cdbb4aa809397cd22f0c8", certificate: "bf53010bbb6d6739c4794605951995a7bf7e731a81aa64ef85f2040462ada4f5"),
    ]

    @Test(arguments: cases)
    func matchesOpenSSL(_ testCase: Case) throws {
        let url = try #require(Bundle.module.url(forResource: testCase.file, withExtension: "der", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        let info = try #require(CertificateFingerprint.info(for: certificate))
        #expect(info.spkiSHA256 == testCase.spki)
        #expect(info.certificateSHA256 == testCase.certificate)
        #expect(!info.subject.isEmpty)
    }

    @Test func pinningDelegateKeyIgnoresBracketsAndCase() {
        #expect(PinningDelegate.key(host: "[FD00::1]", port: 5001) == PinningDelegate.key(host: "fd00::1", port: 5001))
        #expect(PinningDelegate.key(host: "NAS.local", port: 5001) != PinningDelegate.key(host: "nas.local", port: 5002))
    }
}
