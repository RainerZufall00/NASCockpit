import Foundation

/// A 48-bit hardware address, written as `00:11:32:AB:CD:EF`. Accepts `:`, `-`, `.` or no separators.
public struct MACAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ raw: String) {
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !":-. ".contains($0) }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        // All zero, broadcast and multicast addresses never belong to a network port.
        guard bytes.contains(where: { $0 != 0 }), !bytes.allSatisfy({ $0 == 0xFF }), bytes[0] & 0x01 == 0 else { return nil }
        self.bytes = bytes
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = MACAddress(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid MAC address"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What the app needs to wake a NAS or host: its MAC address and, if known, the broadcast address of its network.
public struct WakeOnLANConfig: Hashable, Codable, Sendable {
    public var mac: MACAddress
    /// Directed broadcast of the server's subnet (e.g. 192.168.1.255). Derived from its address and netmask.
    public var broadcast: String?

    public init(mac: MACAddress, broadcast: String? = nil) {
        self.mac = mac
        self.broadcast = broadcast
    }
}

public enum WakeOnLAN {
    /// The usual Wake-on-LAN ports ("discard" and "echo").
    public static let ports: [UInt16] = [9, 7]

    /// 6 × 0xFF followed by the MAC address 16 times (102 bytes).
    public static func magicPacket(for mac: MACAddress) -> Data {
        Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in mac.bytes })
    }

    /// Where the packet goes: the subnet broadcast (known or assumed /24 for each private IPv4 address),
    /// the limited broadcast and each private IPv4 address itself (works while the iPhone still knows its MAC).
    /// VPN addresses (Tailscale 100.64/10) are left out: a sleeping server is not in the VPN.
    public static func targets(config: WakeOnLANConfig, addresses: [ServerAddress]) -> [String] {
        var result: [String] = []
        func add(_ host: String) { if !result.contains(host) { result.append(host) } }
        if let broadcast = config.broadcast, ipv4(broadcast) != nil { add(broadcast) }
        let lanHosts = addresses.compactMap { address -> [UInt8]? in
            guard let bytes = ipv4(address.host), isHomeNetwork(bytes) else { return nil }
            return bytes
        }
        for bytes in lanHosts { add("\(bytes[0]).\(bytes[1]).\(bytes[2]).255") }
        add("255.255.255.255")
        for bytes in lanHosts { add(bytes.map(String.init).joined(separator: ".")) }
        return result
    }

    /// Broadcast address for an IPv4 address and netmask, e.g. 192.168.1.20 / 255.255.255.0 → 192.168.1.255.
    public static func broadcast(address: String, netmask: String) -> String? {
        guard let a = ipv4(address), let m = ipv4(netmask), m != [0, 0, 0, 0] else { return nil }
        return zip(a, m).map { String($0 | ~$1) }.joined(separator: ".")
    }

    static func ipv4(_ raw: String) -> [UInt8]? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func isHomeNetwork(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (10, _), (192, 168): true
        case (172, 16...31): true
        default: false
        }
    }
}

public enum WakeOnLANError: Error, Equatable, Sendable, LocalizedError {
    /// iOS refused the broadcast (no local network permission or no multicast entitlement).
    case notPermitted
    /// Not connected to a Wi-Fi or LAN network.
    case noNetwork
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted:
            String(localized: "iOS did not allow the wake-up packet. Allow NAS Cockpit under Settings → Privacy & Security → Local Network.")
        case .noNetwork:
            String(localized: "The iPhone is not in a local network. Wake-on-LAN only works in the same network as the server.")
        case .failed(let reason):
            String(localized: "The wake-up packet could not be sent: \(reason)")
        }
    }
}
