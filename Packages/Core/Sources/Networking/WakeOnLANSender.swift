import Foundation
import Darwin
import Domain

/// Sends the Wake-on-LAN magic packet over UDP. Synchronous BSD socket calls, so run it off the main actor.
public enum WakeOnLANSender {
    public struct Result: Sendable, Equatable {
        public let sent: Int
        /// iOS refused every broadcast (no multicast entitlement); only direct packets to the server's address left.
        public let broadcastBlocked: Bool
    }

    /// Sends the packet to every target on every Wake-on-LAN port, three times. Succeeds when at least one
    /// datagram left the device; that says nothing about whether the server woke up.
    @concurrent
    public static func send(_ config: WakeOnLANConfig, addresses: [ServerAddress]) async throws(WakeOnLANError) -> Result {
        let packet = WakeOnLAN.magicPacket(for: config.mac)
        let targets = WakeOnLAN.targets(config: config, addresses: addresses)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw .failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var sent = 0
        var broadcastsSent = 0
        var broadcastsTried = 0
        var lastError: Int32 = 0
        for _ in 0..<3 {
            for host in targets {
                for port in WakeOnLAN.ports {
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
                    let result = packet.withUnsafeBytes { buffer in
                        withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    let isBroadcast = host.hasSuffix(".255")
                    if isBroadcast { broadcastsTried += 1 }
                    if result == packet.count {
                        sent += 1
                        if isBroadcast { broadcastsSent += 1 }
                    } else {
                        lastError = errno
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard sent == 0 else { return Result(sent: sent, broadcastBlocked: broadcastsTried > 0 && broadcastsSent == 0) }
        switch lastError {
        case EPERM, EACCES, EHOSTUNREACH: throw .notPermitted
        case ENETUNREACH, ENETDOWN: throw .noNetwork
        default: throw .failed(String(cString: strerror(lastError)))
        }
    }
}
