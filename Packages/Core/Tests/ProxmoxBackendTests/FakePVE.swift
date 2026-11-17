import Foundation
import Synchronization
import Domain
import Networking
@testable import ProxmoxBackend

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static let empty = Data(#"{"data":null}"#.utf8)
}

/// In-memory Proxmox host: tickets, tokens, TFA, OpenID, tasks and the fixtures above.
final class FakePVE: HTTPTransport, Sendable {
    struct Recorded: Sendable {
        let host: String
        let method: String
        let path: String
        let params: [String: String]
        let headers: [String: String]
    }

    struct Configuration: Sendable {
        var hostErrors: [String: TransportError] = [:]
        var password = "s3cret"
        var tokenSecret = "11111111-2222-3333-4444-555555555555"
        var tokenID = "nas-admin@pve!nascockpit"
        /// The password login needs a TOTP code.
        var requiresTFA = false
        var totp = "123456"
        /// Tickets older than this many logins are rejected (simulates expiry).
        var expireTicketsBefore = 0
        /// How many status polls report "running" before a task stops.
        var unfinishedPolls = 2
        /// Exit status of finished tasks.
        var taskExitStatus = "OK"
        /// After a reboot command: requests that fail before the host answers again (all tickets gone).
        var rebootDownRequests = 2
        /// "METHOD path" → HTTP status + message, e.g. ["POST nodes/pve/qemu/100/status/stop": (403, "Permission check failed")].
        var errors: [String: (Int, String)] = [:]
        var openIDRealm = "keycloak"
    }

    struct State: Sendable {
        var config: Configuration
        var requests: [Recorded] = []
        var logins = 0
        var polls = 0
        var issuedTickets: [String: Int] = [:]
        var tfaChallenges: Set<String> = []
        var openIDStates: Set<String> = []
        var createdTokens: [String] = []
        var downRequests = 0
    }

    private let state: Mutex<State>

    init(_ configuration: Configuration = Configuration()) {
        state = Mutex(State(config: configuration))
    }

    var requests: [Recorded] { state.withLock { $0.requests } }
    var loginCount: Int { state.withLock { $0.logins } }
    var createdTokens: [String] { state.withLock { $0.createdTokens } }

    func calls(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func configure(_ change: @Sendable (inout Configuration) -> Void) {
        state.withLock { change(&$0.config) }
    }

    func updatePin(spki: String?, trustedName: String?) {}
    func invalidate() {}

    func send(_ request: URLRequest) async throws -> Data {
        let response = try await fetch(request)
        guard response.isSuccess else { throw TransportError.httpStatus(response.status) }
        return response.body
    }

    func fetch(_ request: URLRequest) async throws -> HTTPResponse {
        let url = request.url!
        let host = url.host()!
        let path = String(url.path().dropFirst("/api2/json/".count)).removingPercentEncoding ?? ""
        let params = PVERequestBuilder.parameters(of: request)
        let method = request.httpMethod ?? "GET"
        let recorded = Recorded(host: host, method: method, path: path, params: params, headers: request.allHTTPHeaderFields ?? [:])

        let outcome: FetchOutcome = state.withLock { state in
            state.requests.append(recorded)
            if let error = state.config.hostErrors[host] { return .fail(error) }
            if state.downRequests > 0 {
                state.downRequests -= 1
                if state.downRequests == 0 { state.issuedTickets = [:] }
                return .fail(.unreachable)
            }
            let key = "\(method) \(path)"
            if let (status, message) = state.config.errors[key] { return .status(status, message) }

            // Unauthenticated endpoints.
            switch key {
            case "GET access/domains":
                return .ok(Fixture.json(["data": [
                    ["realm": "pam", "type": "pam", "comment": "Linux PAM"],
                    ["realm": "pve", "type": "pve"],
                    ["realm": state.config.openIDRealm, "type": "openid", "comment": "Keycloak"],
                ]]))
            case "POST access/ticket":
                return Self.login(params, &state)
            case "POST access/openid/auth-url":
                let oidcState = "state-\(state.openIDStates.count + 1)"
                state.openIDStates.insert(oidcState)
                return .ok(Fixture.json(["data": "https://idp.example/auth?state=\(oidcState)&redirect_uri=\(params["redirect-url"] ?? "")"]))
            case "POST access/openid/login":
                guard params["code"] == "good-code", let oidcState = params["state"], state.openIDStates.contains(oidcState) else {
                    return .status(401, "authentication failure")
                }
                state.logins += 1
                let ticket = "PVE:oidc-user@\(state.config.openIDRealm):\(state.logins)"
                state.issuedTickets[ticket] = state.logins
                return .ok(Fixture.json(["data": ["ticket": ticket, "CSRFPreventionToken": "csrf-\(state.logins)", "username": "oidc-user@\(state.config.openIDRealm)"]]))
            default:
                break
            }

            // Authentication.
            let headers = recorded.headers
            if let authorization = headers["Authorization"] {
                guard authorization == "PVEAPIToken=\(state.config.tokenID)=\(state.config.tokenSecret)" else {
                    return .status(401, "invalid token value!")
                }
            } else if let cookie = headers["Cookie"], cookie.hasPrefix("PVEAuthCookie=") {
                let ticket = String(cookie.dropFirst("PVEAuthCookie=".count))
                guard let issued = state.issuedTickets[ticket], issued > state.config.expireTicketsBefore else {
                    return .status(401, "permission denied - invalid PVE ticket")
                }
                if method != "GET", headers["CSRFPreventionToken"] == nil {
                    return .status(401, "No CSRF token")
                }
            } else {
                return .status(401, "No ticket")
            }

            // Data.
            switch key {
            case "GET version":
                return .ok(Fixture.json(["data": ["version": "8.3.2", "release": "8.3", "repoid": "3e76eec2"]]))
            case "GET cluster/status":
                return .ok(Fixture.json(["data": [
                    ["type": "cluster", "name": "home", "quorate": 1, "nodes": 2],
                    ["type": "node", "name": "pve2", "local": 0, "online": 1],
                    ["type": "node", "name": "pve", "local": 1, "online": 1],
                ]]))
            case "GET nodes":
                return .ok(Fixture.json(["data": [["node": "pve", "status": "online"], ["node": "pve2", "status": "online"]]]))
            case "GET cluster/resources":
                return .ok(Fixture.data("cluster_resources"))
            case "GET nodes/pve/status":
                return .ok(Fixture.data("node_status"))
            case "GET nodes/pve/storage":
                return .ok(Fixture.data("node_storage"))
            case "GET nodes/pve/disks/list":
                return .ok(Fixture.data("disks"))
            case "GET nodes/pve/rrddata":
                return .ok(Fixture.json(["data": [["time": 1730000000, "netin": 1200000.5, "netout": 300000.25]]]))
            case "GET nodes/pve/apt/update":
                return .ok(Fixture.data("apt_update"))
            case "GET nodes/pve/qemu/100/snapshot":
                return .ok(Fixture.json(["data": [
                    ["name": "current", "parent": "before_update", "running": 1, "description": "You are here!"],
                    ["name": "clean", "snaptime": 1720000000, "description": ""],
                    ["name": "before_update", "snaptime": 1730000000, "vmstate": 1, "parent": "clean", "description": "HA 2026.10\n"],
                ]]))
            case "POST nodes/pve/apt/update", "POST nodes/pve/vzdump",
                 _ where key.hasPrefix("POST nodes/") && key.contains("/snapshot"),
                 _ where key.hasPrefix("DELETE nodes/") && key.contains("/snapshot/"),
                 _ where key.hasPrefix("POST nodes/") && key.contains("/status/"):
                state.polls = 0
                return .ok(Fixture.json(["data": "UPID:pve:0001:0002:0003:\(key.split(separator: "/").last ?? "task")::root@pam:"]))
            case _ where key.hasPrefix("GET nodes/pve/tasks/UPID") && key.hasSuffix("/status"):
                state.polls += 1
                let done = state.polls > state.config.unfinishedPolls
                var body: [String: Any] = ["status": done ? "stopped" : "running", "type": "qmstart", "user": "root@pam"]
                if done { body["exitstatus"] = state.config.taskExitStatus }
                return .ok(Fixture.json(["data": body]))
            case "GET nodes/pve/tasks":
                return .ok(Fixture.data("tasks"))
            case "GET nodes/pve2/tasks":
                return .ok(Fixture.json(["data": [], "total": 0]))
            case "GET cluster/backup":
                return .ok(Fixture.data("backup_jobs"))
            case _ where key.hasPrefix("GET cluster/backup/"):
                let id = String(key.dropFirst("GET cluster/backup/".count))
                let jobs = try! JSONSerialization.jsonObject(with: Fixture.data("backup_jobs")) as! [String: [[String: Any]]]
                guard let job = jobs["data"]!.first(where: { $0["id"] as? String == id }) else { return .status(500, "no such job") }
                return .ok(Fixture.json(["data": job]))
            case _ where key.hasPrefix("GET nodes/pve/storage/") && key.hasSuffix("/content"):
                return .ok(Fixture.json(["data": [["volid": "nas-backup:backup/vzdump-qemu-100.vma.zst", "ctime": 1729800100, "size": 123, "vmid": 100, "format": "vma.zst"]]]))
            case _ where key.hasPrefix("DELETE nodes/pve/tasks/"):
                return .ok(Fixture.empty)
            case "POST nodes/pve/status":
                if params["command"] == "reboot" { state.downRequests = state.config.rebootDownRequests }
                return .ok(Fixture.empty)
            case "GET nodes/pve/qemu/100/agent/network-get-interfaces":
                return .ok(Fixture.json(["data": ["result": [
                    ["name": "lo", "ip-addresses": [["ip-address": "127.0.0.1", "ip-address-type": "ipv4"], ["ip-address": "::1", "ip-address-type": "ipv6"]]],
                    ["name": "eth0", "ip-addresses": [["ip-address": "fe80::1", "ip-address-type": "ipv6"], ["ip-address": "192.168.1.100", "ip-address-type": "ipv4"], ["ip-address": "fd00::100", "ip-address-type": "ipv6"]]],
                ]]]))
            case "GET nodes/pve/qemu/101/agent/network-get-interfaces":
                return .status(500, "No QEMU guest agent configured")
            case "GET nodes/pve/lxc/200/interfaces":
                return .ok(Fixture.json(["data": [["name": "lo", "inet": "127.0.0.1/8"], ["name": "eth0", "inet": "192.168.1.200/24", "inet6": "fe80::2/64", "hwaddr": "aa"]]]))
            case "GET nodes/pve/syslog":
                return .ok(Fixture.data("syslog"))
            case _ where key.hasPrefix("POST access/users/") && key.contains("/token/"):
                let parts = key.split(separator: "/")
                let user = String(parts[2]), name = String(parts[4])
                let id = "\(user)!\(name)"
                state.createdTokens.append(id)
                return .ok(Fixture.json(["data": ["full-tokenid": id, "value": "new-secret", "info": ["privsep": 0]]]))
            default:
                return .status(501, "unknown endpoint \(key)")
            }
        }

        switch outcome {
        case .ok(let data): return HTTPResponse(status: 200, body: data)
        case .status(let status, let message): return HTTPResponse(status: status, body: Fixture.json(["data": NSNull(), "message": message]))
        case .fail(let error): throw error
        }
    }

    private static func login(_ params: [String: String], _ state: inout State) -> FetchOutcome {
        guard let username = params["username"], let password = params["password"] else { return .status(401, "authentication failure") }
        func issue(_ user: String) -> FetchOutcome {
            state.logins += 1
            let ticket = "PVE:\(user):\(state.logins)"
            state.issuedTickets[ticket] = state.logins
            return .ok(Fixture.json(["data": ["ticket": ticket, "CSRFPreventionToken": "csrf-\(state.logins)", "username": user]]))
        }
        if let challenge = params["tfa-challenge"] {
            guard state.tfaChallenges.contains(challenge), password == "totp:\(state.config.totp)" else { return .status(401, "authentication failure") }
            state.tfaChallenges.remove(challenge)
            return issue(username)
        }
        if password.hasPrefix("PVE:") {
            // Ticket renewal.
            guard let issued = state.issuedTickets[password], issued > state.config.expireTicketsBefore else { return .status(401, "authentication failure") }
            return issue(username)
        }
        guard password == state.config.password else { return .status(401, "authentication failure") }
        if state.config.requiresTFA {
            let challenge = "PVE:!tfa!\(username):challenge-\(state.tfaChallenges.count + 1)"
            state.tfaChallenges.insert(challenge)
            return .ok(Fixture.json(["data": ["ticket": challenge, "CSRFPreventionToken": "", "username": username, "NeedTFA": 1]]))
        }
        return issue(username)
    }

}

enum FetchOutcome {
    case ok(Data), status(Int, String), fail(TransportError)
}

/// Collects backend events for assertions.
final class EventRecorder: Sendable {
    private let events = Mutex<[BackendEvent]>([])
    var all: [BackendEvent] { events.withLock { $0 } }
    func record(_ event: BackendEvent) { events.withLock { $0.append(event) } }
}

/// A browser that always approves.
struct FakeAuthorizer: OpenIDAuthorizer {
    var code = "good-code"

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(callbackScheme)://oidc?code=\(code)&state=\(state)")!
    }
}

struct TestBackend {
    let backend: ProxmoxBackend
    let transport: FakePVE
    let events: EventRecorder
    let profile: ServerProfile

    static func make(
        authMethod: AuthMethod = .password,
        username: String = "nas-admin@pve",
        secret: String? = "s3cret",
        configuration: FakePVE.Configuration = FakePVE.Configuration(),
        authorizer: (any OpenIDAuthorizer)? = nil,
        connect: Bool = true
    ) async throws -> TestBackend {
        let profile = ServerProfile(
            name: "Test PVE", addresses: [ServerAddress(host: "pve.lan", port: 8006, label: "LAN")],
            backend: .proxmox, authMethod: authMethod, username: username
        )
        let transport = FakePVE(configuration)
        let credentials = InMemoryCredentialProvider()
        if let secret {
            await credentials.set(ServerCredentials(password: secret), for: profile.id)
        }
        var policy = PVEConnection.Policy()
        policy.taskPollInterval = .milliseconds(1)
        policy.rebootInitialDelay = .milliseconds(1)
        policy.rebootMaxDelay = .milliseconds(1)
        policy.rebootDeadline = .seconds(5)
        policy.sleep = { _ in await Task.yield() }
        let backend = ProxmoxBackend(profile: profile, credentials: credentials, deviceName: "Tests", openID: authorizer, transport: transport, policy: policy)
        let recorder = EventRecorder()
        let events = backend.events
        Task {
            for await event in events { recorder.record(event) }
        }
        if authorizer != nil { await backend.setInteractiveSignIn(true) }
        if connect { try await backend.connect(otp: nil) }
        return TestBackend(backend: backend, transport: transport, events: recorder, profile: profile)
    }
}
