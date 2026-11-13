import Foundation
import Testing
@testable import Domain

@Suite("Wake-on-LAN")
struct WakeOnLANTests {
    @Test func parsesCommonNotations() throws {
        for raw in ["00:11:32:ab:cd:ef", "00-11-32-AB-CD-EF", "0011.32ab.cdef", " 001132ABCDEF "] {
            #expect(MACAddress(raw)?.description == "00:11:32:AB:CD:EF", "\(raw)")
        }
        for raw in ["", "00:11:32:ab:cd", "00:11:32:ab:cd:eg", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "01:00:5E:00:00:01"] {
            #expect(MACAddress(raw) == nil, "\(raw)")
        }
    }

    @Test func magicPacketIsSyncStreamPlusSixteenCopies() throws {
        let mac = try #require(MACAddress("00:11:32:AB:CD:EF"))
        let packet = WakeOnLAN.magicPacket(for: mac)
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        for copy in 0..<16 {
            let start = 6 + copy * 6
            #expect(Array(packet[start..<start + 6]) == mac.bytes)
        }
    }

    @Test func targetsPreferTheKnownBroadcastAndSkipVPN() throws {
        let mac = try #require(MACAddress("00:11:32:AB:CD:EF"))
        let addresses = [
            ServerAddress(host: "192.168.1.20"),
            ServerAddress(host: "100.101.102.103", label: "Tailscale"),
            ServerAddress(host: "nas.example.com"),
        ]
        #expect(WakeOnLAN.targets(config: WakeOnLANConfig(mac: mac, broadcast: "192.168.0.255"), addresses: addresses)
                == ["192.168.0.255", "192.168.1.255", "255.255.255.255", "192.168.1.20"])
        #expect(WakeOnLAN.targets(config: WakeOnLANConfig(mac: mac), addresses: [ServerAddress(host: "nas.local")])
                == ["255.255.255.255"])
    }

    @Test func broadcastFromNetmask() {
        #expect(WakeOnLAN.broadcast(address: "192.168.1.20", netmask: "255.255.255.0") == "192.168.1.255")
        #expect(WakeOnLAN.broadcast(address: "10.1.2.3", netmask: "255.255.252.0") == "10.1.3.255")
        #expect(WakeOnLAN.broadcast(address: "10.1.2.3", netmask: "nope") == nil)
    }

    @Test func profilesWithoutWakeOnLANStillDecode() throws {
        let profile = ServerProfile(name: "NAS", addresses: [], username: "admin",
                                    wakeOnLAN: WakeOnLANConfig(mac: try #require(MACAddress("00:11:32:AB:CD:EF"))))
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(ServerProfile.self, from: data).wakeOnLAN == profile.wakeOnLAN)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["wakeOnLAN"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(ServerProfile.self, from: old).wakeOnLAN == nil)
    }
}
