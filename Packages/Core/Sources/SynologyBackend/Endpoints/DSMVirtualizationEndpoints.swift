import Foundation
import Domain

// Virtual Machine Manager (documented in Synology's Virtual Machine Manager API guide).

extension DSMEndpoints {
    enum Virtualization {
        static let guestAPI = "SYNO.Virtualization.API.Guest"
        static let actionAPI = "SYNO.Virtualization.API.Guest.Action"

        static var guests: DSMEndpoint<VMMGuestListDTO> {
            DSMEndpoint(api: guestAPI, method: "list", versions: 1...1, documentation: .official, timeout: 20)
        }

        /// `poweron`, `poweroff` (pull the plug) and `shutdown` (ACPI). A reboot is shutdown + poweron.
        static func perform(_ method: String, guestID: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: actionAPI, method: method, versions: 1...1, params: ["guest_id": jsonString(guestID)],
                        isWrite: true, documentation: .official, timeout: 30)
        }
    }
}

/// `SYNO.Virtualization.API.Guest` list: `guests: [{guest_id, guest_name, status, vcpu_num, vram_size, host_name, description, autorun}]`
struct VMMGuestListDTO: Decodable, Sendable {
    struct Guest: Decodable, Sendable {
        let id: String
        let name: String
        let status: String?
        let vcpu: Int?
        /// MB
        let vram: Int64?
        let hostName: String?
        let description: String?

        private enum CodingKeys: String, CodingKey { case guest_id, guest_name, status, vcpu_num, vram_size, host_name, description }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.guest_id) ?? ""
            name = c.lossyString(.guest_name) ?? id
            status = c.lossyString(.status)
            vcpu = c.lossyInt(.vcpu_num)
            vram = c.lossyInt64(.vram_size)
            hostName = c.lossyString(.host_name)
            description = c.lossyString(.description)
        }
    }

    let guests: [Guest]

    private enum CodingKeys: String, CodingKey { case guests }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guests = c.lossyArray(Guest.self, .guests).filter { !$0.id.isEmpty }
    }
}

extension DSMMapping {
    static func guests(_ list: VMMGuestListDTO) -> [VirtualGuest] {
        list.guests.enumerated().map { index, guest in
            VirtualGuest(
                id: guest.id,
                // VMM has no numeric IDs; the list position keeps the sort stable.
                vmid: index + 1,
                name: guest.name,
                node: guest.hostName ?? "",
                kind: .virtualMachine,
                status: vmmStatus(guest.status),
                cores: guest.vcpu,
                maxMemoryBytes: guest.vram.map { $0 * 1024 * 1024 },
                tags: guest.description.map { $0.isEmpty ? [] : [$0] } ?? []
            )
        }
    }

    static func vmmStatus(_ raw: String?) -> GuestStatus {
        switch raw?.lowercased() {
        case "running": .running
        case "shutdown", "stopped", "off", "poweroff": .stopped
        case "paused", "suspended": .paused
        default: .unknown
        }
    }
}
