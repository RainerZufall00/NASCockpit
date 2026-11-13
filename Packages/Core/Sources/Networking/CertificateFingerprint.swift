import CryptoKit
import Foundation
import Security
import Domain

/// Computes SPKI and certificate fingerprints.
///
/// `SecKeyCopyExternalRepresentation` returns only the raw key (PKCS#1 for RSA,
/// X9.63 point for EC). The SubjectPublicKeyInfo DER is rebuilt here so the hash
/// matches `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256`.
public enum CertificateFingerprint {
    public static func info(for trust: SecTrust) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return info(for: leaf)
    }

    public static func info(for certificate: SecCertificate) -> CertificateInfo? {
        guard let spki = spkiSHA256(of: certificate) else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        return CertificateInfo(spkiSHA256: spki, certificateSHA256: hex(SHA256.hash(data: der)), subject: subject)
    }

    public static func spkiSHA256(of certificate: SecCertificate) -> String? {
        guard
            let key = SecCertificateCopyKey(certificate),
            let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
            let type = attributes[kSecAttrKeyType],
            let bits = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue,
            let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
            let der = spkiDER(keyType: "\(type)", keySizeInBits: bits, externalRepresentation: raw)
        else { return nil }
        return hex(SHA256.hash(data: der))
    }

    static func spkiDER(keyType: String, keySizeInBits: Int, externalRepresentation raw: Data) -> Data? {
        let algorithm: [UInt8]
        if keyType == (kSecAttrKeyTypeRSA as String) {
            // SEQUENCE { OID rsaEncryption, NULL }
            algorithm = tlv(0x30, [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            let ecPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
            let curve: [UInt8]
            switch keySizeInBits {
            case 256: curve = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
            case 384: curve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]
            case 521: curve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23]
            default: return nil
            }
            algorithm = tlv(0x30, ecPublicKey + curve)
        } else {
            return nil
        }
        let bitString = tlv(0x03, [0x00] + [UInt8](raw))
        return Data(tlv(0x30, algorithm + bitString))
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
