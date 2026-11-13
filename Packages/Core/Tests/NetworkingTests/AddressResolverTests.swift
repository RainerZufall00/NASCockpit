import Foundation
import Synchronization
import Testing
import Domain
@testable import Networking

@Suite("Address selection")
struct AddressResolverTests {
    let lan = ServerAddress(host: "192.168.1.10", label: "LAN")
    let tailscale = ServerAddress(host: "100.64.0.10", label: "Tailscale")
    let wireguard = ServerAddress(host: "10.8.0.10", label: "WireGuard")
    let foreign = CertificateInfo(spkiSHA256: "foreign", certificateSHA256: "c", subject: "other device")

    final class Recorder: Sendable {
        private let hosts = Mutex<[String]>([])
        func append(_ host: String) { hosts.withLock { $0.append(host) } }
        var all: [String] { hosts.withLock { $0 } }
    }

    /// Records the probe order and returns a scripted outcome per host.
    func resolver(_ outcomes: [String: ProbeOutcome], order: Recorder) -> AddressResolver {
        AddressResolver { address in
            order.append(address.host)
            return outcomes[address.host] ?? .unreachable
        }
    }

    @Test func triesLastReachedAddressFirst() async {
        let order = Recorder()
        let result = await resolver([tailscale.host: .reachable], order: order)
            .resolve([lan, tailscale, wireguard], lastReachedID: tailscale.id)
        #expect(result == .selected(tailscale))
        #expect(order.all == [tailscale.host])
    }

    @Test func fallsBackInConfiguredOrder() async {
        let order = Recorder()
        let result = await resolver([wireguard.host: .reachable], order: order)
            .resolve([lan, tailscale, wireguard], lastReachedID: tailscale.id)
        #expect(result == .selected(wireguard))
        #expect(order.all == [tailscale.host, lan.host, wireguard.host])
    }

    @Test func foreignFingerprintCountsAsUnreachableWhenAnotherAddressMatches() async {
        let order = Recorder()
        let result = await resolver([lan.host: .mismatch(foreign), tailscale.host: .reachable], order: order)
            .resolve([lan, tailscale], lastReachedID: nil)
        #expect(result == .selected(tailscale))
    }

    @Test func warnsOnlyWhenNoAddressMatches() async {
        let order = Recorder()
        let result = await resolver([lan.host: .mismatch(foreign), tailscale.host: .unreachable], order: order)
            .resolve([lan, tailscale], lastReachedID: nil)
        #expect(result == .fingerprintChanged(observed: foreign))
    }

    @Test func untrustedCertificateAsksForTrust() async {
        let order = Recorder()
        let result = await resolver([lan.host: .untrusted(foreign)], order: order)
            .resolve([lan, tailscale], lastReachedID: nil)
        #expect(result == .needsTrust(lan, foreign))
    }

    @Test func prefersSystemTrustedAddressOverTOFU() async {
        let order = Recorder()
        let result = await resolver([lan.host: .untrusted(foreign), tailscale.host: .reachable], order: order)
            .resolve([lan, tailscale], lastReachedID: nil)
        #expect(result == .selected(tailscale))
    }

    @Test func allUnreachable() async {
        let order = Recorder()
        let result = await resolver([:], order: order).resolve([lan, tailscale], lastReachedID: nil)
        #expect(result == .unreachable)
    }

    @Test func unknownLastReachedIDKeepsOrder() {
        let ordered = AddressResolver.orderedAddresses([lan, tailscale], lastReachedID: UUID())
        #expect(ordered == [lan, tailscale])
    }

    @Test func ipv6HostsGetBrackets() {
        #expect(ServerAddress(host: "fd00::10").urlHost == "[fd00::10]")
        #expect(ServerAddress(host: "nas.local").urlHost == "nas.local")
    }
}
