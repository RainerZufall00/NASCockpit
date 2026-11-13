import Foundation
import Domain

/// All Proxmox endpoints in one place. When a PVE release changes an API, adapt it here (plus the tests).
enum PVEEndpoints {
    enum Access {
        static let ticketPath = "access/ticket"

        static func login(username: String, password: String) -> PVEEndpoint<TicketDTO> {
            PVEEndpoint(.post, ticketPath, params: ["username": username, "password": password], timeout: 20)
        }

        /// Second step of a password login with two-factor authentication (TOTP).
        static func loginTFA(username: String, challenge: String, code: String) -> PVEEndpoint<TicketDTO> {
            PVEEndpoint(.post, ticketPath, params: ["username": username, "tfa-challenge": challenge, "password": "totp:\(code)"], timeout: 20)
        }

        /// A ticket can be renewed by using it as the password.
        static func renew(username: String, ticket: String) -> PVEEndpoint<TicketDTO> {
            PVEEndpoint(.post, ticketPath, params: ["username": username, "password": ticket], timeout: 20)
        }

        /// Readable without signing in. Doubles as the reachability probe.
        static var domains: PVEEndpoint<[DomainDTO]> {
            PVEEndpoint(.get, "access/domains", timeout: 10)
        }

        static func openIDAuthURL(realm: String, redirectURL: String) -> PVEEndpoint<AuthURLDTO> {
            PVEEndpoint(.post, "access/openid/auth-url", params: ["realm": realm, "redirect-url": redirectURL], timeout: 20)
        }

        static func openIDLogin(code: String, state: String, redirectURL: String) -> PVEEndpoint<TicketDTO> {
            PVEEndpoint(.post, "access/openid/login", params: ["code": code, "state": state, "redirect-url": redirectURL], timeout: 30)
        }

        /// A token without privilege separation inherits the user's permissions.
        static func createToken(user: String, name: String, comment: String) -> PVEEndpoint<TokenCreateDTO> {
            PVEEndpoint(.post, "access/users/\(escape(user))/token/\(escape(name))", params: ["privsep": "0", "comment": comment], timeout: 20)
        }
    }

    static var version: PVEEndpoint<VersionDTO> { PVEEndpoint(.get, "version", timeout: 10) }

    enum Cluster {
        static var status: PVEEndpoint<[ClusterStatusDTO]> { PVEEndpoint(.get, "cluster/status") }
        static var nodes: PVEEndpoint<[NodeDTO]> { PVEEndpoint(.get, "nodes") }
        static var guests: PVEEndpoint<[ResourceDTO]> { PVEEndpoint(.get, "cluster/resources", params: ["type": "vm"]) }
        static var backupJobs: PVEEndpoint<[BackupJobDTO]> { PVEEndpoint(.get, "cluster/backup") }
        static func backupJob(_ id: String) -> PVEEndpoint<BackupJobDTO> { PVEEndpoint(.get, "cluster/backup/\(escape(id))") }
        static var notBackedUp: PVEEndpoint<[NotBackedUpDTO]> { PVEEndpoint(.get, "cluster/backup-info/not-backed-up") }
    }

    enum Node {
        static func status(_ node: String) -> PVEEndpoint<NodeStatusDTO> { PVEEndpoint(.get, "nodes/\(escape(node))/status") }
        static func storage(_ node: String) -> PVEEndpoint<[StorageDTO]> { PVEEndpoint(.get, "nodes/\(escape(node))/storage") }
        static func disks(_ node: String) -> PVEEndpoint<[DiskDTO]> { PVEEndpoint(.get, "nodes/\(escape(node))/disks/list") }
        /// Minute averages of the last hour; the last point gives the current network throughput.
        static func rrd(_ node: String) -> PVEEndpoint<[RRDPointDTO]> {
            PVEEndpoint(.get, "nodes/\(escape(node))/rrddata", params: ["timeframe": "hour", "cf": "AVERAGE"])
        }

        static func power(_ node: String, _ action: PowerAction) -> PVEEndpoint<PVEEmpty> {
            PVEEndpoint(.post, "nodes/\(escape(node))/status", params: ["command": action == .restart ? "reboot" : "shutdown"], timeout: 30)
        }

        static func taskStatus(_ node: String, upid: String) -> PVEEndpoint<TaskStatusDTO> {
            PVEEndpoint(.get, "nodes/\(escape(node))/tasks/\(escape(upid))/status")
        }

        static func tasks(_ node: String, type: String, limit: Int) -> PVEEndpoint<[TaskListEntryDTO]> {
            PVEEndpoint(.get, "nodes/\(escape(node))/tasks", params: ["typefilter": type, "limit": String(limit), "source": "all"])
        }

        static func stopTask(_ node: String, upid: String) -> PVEEndpoint<PVEEmpty> {
            PVEEndpoint(.delete, "nodes/\(escape(node))/tasks/\(escape(upid))", timeout: 20)
        }

        static func syslog(_ node: String, start: Int, limit: Int, since: Date?, until: Date?, service: String?) -> PVEEndpoint<[SyslogLineDTO]> {
            var params = ["start": String(start), "limit": String(limit)]
            if let since { params["since"] = journalDate(since) }
            if let until { params["until"] = journalDate(until) }
            if let service { params["service"] = service }
            return PVEEndpoint(.get, "nodes/\(escape(node))/syslog", params: params, timeout: 20)
        }

        static func backupContent(_ node: String, storage: String) -> PVEEndpoint<[ContentDTO]> {
            PVEEndpoint(.get, "nodes/\(escape(node))/storage/\(escape(storage))/content", params: ["content": "backup"], timeout: 30)
        }

        static func vzdump(_ node: String, params: [String: String]) -> PVEEndpoint<PVEUPID> {
            PVEEndpoint(.post, "nodes/\(escape(node))/vzdump", params: params, timeout: 30)
        }

        static func journalDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
    }

    enum Guest {
        /// QEMU guest agent: interfaces with their addresses. Fails when the agent is not running.
        static func agentInterfaces(_ guest: VirtualGuest) -> PVEEndpoint<AgentInterfacesDTO> {
            PVEEndpoint(.get, "nodes/\(escape(guest.node))/qemu/\(guest.vmid)/agent/network-get-interfaces", timeout: 10)
        }

        static func containerInterfaces(_ guest: VirtualGuest) -> PVEEndpoint<[ContainerInterfaceDTO]> {
            PVEEndpoint(.get, "nodes/\(escape(guest.node))/lxc/\(guest.vmid)/interfaces", timeout: 10)
        }

        private static func base(_ guest: VirtualGuest) -> String {
            "nodes/\(escape(guest.node))/\(guest.kind == .virtualMachine ? "qemu" : "lxc")/\(guest.vmid)"
        }

        static func snapshots(_ guest: VirtualGuest) -> PVEEndpoint<[SnapshotDTO]> {
            PVEEndpoint(.get, "\(base(guest))/snapshot", timeout: 15)
        }

        /// `vmstate` (RAM) exists only for VMs.
        static func createSnapshot(_ guest: VirtualGuest, name: String, description: String, includeMemory: Bool) -> PVEEndpoint<PVEUPID> {
            var params = ["snapname": name]
            if !description.isEmpty { params["description"] = description }
            if guest.kind == .virtualMachine, includeMemory { params["vmstate"] = "1" }
            return PVEEndpoint(.post, "\(base(guest))/snapshot", params: params, timeout: 30)
        }

        static func rollback(_ guest: VirtualGuest, snapshot: String) -> PVEEndpoint<PVEUPID> {
            PVEEndpoint(.post, "\(base(guest))/snapshot/\(escape(snapshot))/rollback", timeout: 30)
        }

        static func deleteSnapshot(_ guest: VirtualGuest, snapshot: String) -> PVEEndpoint<PVEUPID> {
            PVEEndpoint(.delete, "\(base(guest))/snapshot/\(escape(snapshot))", timeout: 30)
        }

        static func action(_ guest: VirtualGuest, _ action: GuestAction) -> PVEEndpoint<PVEUPID> {
            let kind = guest.kind == .virtualMachine ? "qemu" : "lxc"
            return PVEEndpoint(.post, "nodes/\(escape(guest.node))/\(kind)/\(guest.vmid)/status/\(action.rawValue)", timeout: 30)
        }
    }

    enum Apt {
        static func updates(_ node: String) -> PVEEndpoint<[AptUpdateDTO]> {
            PVEEndpoint(.get, "nodes/\(escape(node))/apt/update", timeout: 20)
        }

        /// `apt-get update`: refreshes the package index. Installing is not offered by the API.
        static func refresh(_ node: String) -> PVEEndpoint<PVEUPID> {
            PVEEndpoint(.post, "nodes/\(escape(node))/apt/update", params: ["quiet": "1"], timeout: 30)
        }
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@!")) ?? value
    }
}

struct ContentDTO: Decodable, Sendable {
    struct Verification: Decodable, Sendable {
        let state: String?
    }

    let volid: String?
    let ctime: Double?
    let size: Int64?
    let vmid: Int?
    let notes: String?
    let format: String?
    let verification: Verification?
}
