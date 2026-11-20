import Foundation
import Synchronization
import Domain
import Networking
@testable import SynologyBackend

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func error(_ code: Int) -> Data {
        Data(#"{"success":false,"error":{"code":\#(code)}}"#.utf8)
    }

    static let ok = Data(#"{"success":true}"#.utf8)
}

/// In-memory DSM that implements just enough of the Web API for connection tests.
final class FakeDSM: HTTPTransport, Sendable {
    struct Recorded: Sendable {
        let host: String
        let path: String
        let method: String
        let params: [String: String]
        let urlQuery: String?
    }

    enum LoginResult: Sendable {
        case success
        case error(Int)
    }

    struct Configuration: Sendable {
        /// Per host: an error to throw instead of answering.
        var hostErrors: [String: TransportError] = [:]
        /// Scripted login results, consumed in order. Default afterwards: success.
        var loginResults: [LoginResult] = []
        /// SIDs for which data calls answer 106.
        var expiredSIDs: Set<String> = []
        var alwaysExpire = false
        var deviceID = "device-123"
        /// Artificial latency for data calls, to make parallel requests overlap.
        var dataLatency: Duration = .zero
        /// "api/method" → DSM error code, e.g. ["SYNO.Core.Package.Control/stop": 105].
        var errors: [String: Int] = [:]
        /// How many status polls report "not finished" before a task finishes.
        var unfinishedPolls = 2
        /// After the DSM update starts: probes that fail before the NAS answers again.
        var rebootDownProbes = 2
        /// Probes that still answer (installation phase) before the NAS goes down.
        var rebootUpProbes = 0
        /// Login error codes returned right after the reboot (services still starting).
        var loginErrorsAfterReboot: [Int] = []
        /// Guest list answers "shutdown" for the rebooting VM after this many list calls.
        var vmmStopsAfterLists = 1
        /// Hyper Backup task IDs whose destination answers "offline" to `status`.
        var backupTargetsOffline: Set<String> = []
        /// After `backup`, task 3 ("Offsite") reports a failed run instead of starting.
        var backupFailsAfterStart = false
        /// Security Advisor reports a running scan.
        var securityScanRunning = false
        /// Error code for log queries that carry any of `rejectedLogParameters` (like DSM 7.2 answering 5017).
        var rejectsFilteredLogs: Int?
        var rejectedLogParameters: Set<String> = ["target"]
        /// DSM already downloaded its update on its own (`basic_status` answers "ready_upgrade").
        var systemUpdateDownloaded = false
    }

    struct State: Sendable {
        var config: Configuration
        var requests: [Recorded] = []
        var logins = 0
        var polls = 0
        /// nil = not rebooting.
        var reboot: (up: Int, down: Int)?
        /// SIDs issued before the reboot are invalid afterwards.
        var invalidSIDs: Set<String> = []
        var issuedSIDs: Set<String> = []
        var vmmLists = 0
        var vmmShutDown: Set<String> = []
        var backupStarted = false
    }

    private let state: Mutex<State>

    init(_ configuration: Configuration = Configuration()) {
        state = Mutex(State(config: configuration))
    }

    /// Calls with that api/method, in order.
    func calls(_ api: String, _ method: String) -> [Recorded] {
        requests.filter { $0.params["api"] == api && $0.params["method"] == method }
    }

    func configure(_ change: @Sendable (inout Configuration) -> Void) {
        state.withLock { change(&$0.config) }
    }

    var requests: [Recorded] { state.withLock { $0.requests } }
    var loginCount: Int { state.withLock { $0.logins } }
    var dataRequests: [Recorded] { requests.filter { $0.params["api"] != "SYNO.API.Info" && $0.params["api"] != "SYNO.API.Auth" } }

    func updatePinnedSPKI(_ spki: String?) {}
    func invalidate() {}

    func send(_ request: URLRequest) async throws -> Data {
        let url = request.url!
        let host = url.host()!
        let params = DSMRequestBuilder.parameters(of: request)
        let recorded = Recorded(
            host: host,
            path: url.lastPathComponent,
            method: request.httpMethod ?? "GET",
            params: params,
            urlQuery: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        )

        enum Outcome { case data(Data), fail(TransportError), delayed(Data, Duration) }

        let outcome: Outcome = state.withLock { state in
            state.requests.append(recorded)
            if let error = state.config.hostErrors[host] { return .fail(error) }

            let api = params["api"] ?? ""
            let method = params["method"] ?? ""

            // Simulated restart: first still up (installing), then down, then back with all sessions gone.
            if let reboot = state.reboot {
                let isProbe = recorded.path == "query.cgi" && params["query"] != "all"
                if reboot.up > 0 {
                    if isProbe { state.reboot = (reboot.up - 1, reboot.down) }
                } else if reboot.down > 0 {
                    if isProbe { state.reboot = (0, reboot.down - 1) }
                    return .fail(.unreachable)
                } else {
                    state.reboot = nil
                    state.invalidSIDs = state.issuedSIDs
                }
            }

            if recorded.path == "query.cgi" {
                return .data(params["query"] == "all" ? Fixture.data("api_info") : Data(#"{"success":true,"data":{}}"#.utf8))
            }

            switch (api, method) {
            case ("SYNO.API.Auth", "login"):
                if !state.invalidSIDs.isEmpty, !state.config.loginErrorsAfterReboot.isEmpty {
                    return .data(Fixture.error(state.config.loginErrorsAfterReboot.removeFirst()))
                }
                state.logins += 1
                let result = state.config.loginResults.isEmpty ? .success : state.config.loginResults.removeFirst()
                switch result {
                case .error(let code):
                    return .data(Fixture.error(code))
                case .success:
                    let sid = "sid-\(state.logins)"
                    state.issuedSIDs.insert(sid)
                    var payload: [String: String] = ["sid": sid, "synotoken": "token-\(state.logins)"]
                    if params["otp_code"] != nil { payload["did"] = state.config.deviceID }
                    let body = try! JSONSerialization.data(withJSONObject: ["success": true, "data": payload])
                    return .data(body)
                }
            case ("SYNO.API.Auth", "logout"):
                return .data(Fixture.ok)
            default:
                let sid = params["_sid"] ?? ""
                if state.config.alwaysExpire || state.config.expiredSIDs.contains(sid) || state.invalidSIDs.contains(sid) {
                    return .delayed(Fixture.error(106), state.config.dataLatency)
                }
                if let code = state.config.errors["\(api)/\(method)@v\(params["version"] ?? "")"] ?? state.config.errors["\(api)/\(method)"] {
                    return .data(Fixture.error(code))
                }
                if api == "SYNO.Core.SyslogClient.Log", let code = state.config.rejectsFilteredLogs,
                   state.config.rejectedLogParameters.contains(where: { params[$0] != nil }) {
                    return .data(Fixture.error(code))
                }
                switch (api, method) {
                case ("SYNO.Core.Package.Installation", "install"):
                    state.polls = 0
                    return .data(Data(#"{"success":true,"data":{"progress":0,"taskid":"@SYNOPKG_DOWNLOAD_\#(params["name"] ?? "")"}}"#.utf8))
                case ("SYNO.Core.Package.Installation", "upgrade"):
                    state.polls = 0
                    return .data(Data(#"{"success":true,"data":{"taskid":"@SYNOPKG_UPGRADE_1"}}"#.utf8))
                case ("SYNO.Core.Package.Installation", "status"), ("SYNO.Core.Upgrade.Server.Download", "progress"):
                    state.polls += 1
                    let done = state.polls > state.config.unfinishedPolls
                    let percent = done ? 100 : state.polls * 100 / (state.config.unfinishedPolls + 1)
                    return .data(Data(#"{"success":true,"data":{"finished":\#(done),"progress":\#(percent)}}"#.utf8))
                case ("SYNO.Core.Upgrade", "basic_status"):
                    let status = state.config.systemUpdateDownloaded ? "ready_upgrade" : "none"
                    return .data(Data(#"{"success":true,"data":{"status":"\#(status)","target":"update","allow_upgrade":true}}"#.utf8))
                case ("SYNO.Core.Upgrade.Server.Download", "start"):
                    state.polls = 0
                    return .data(Fixture.ok)
                case ("SYNO.Core.Upgrade", "start"), ("SYNO.Core.System", "reboot"):
                    state.reboot = (state.config.rebootUpProbes, state.config.rebootDownProbes)
                    return .data(Fixture.ok)
                case ("SYNO.FileStation.CopyMove", "start"):
                    state.polls = 0
                    return .data(Data(#"{"success":true,"data":{"taskid":"FileStation_51D00B7912CDE0B0"}}"#.utf8))
                case ("SYNO.FileStation.Delete", "start"):
                    state.polls = 0
                    return .data(Data(#"{"success":true,"data":{"taskid":"FileStation_51D00B7912CDE0B1"}}"#.utf8))
                case ("SYNO.FileStation.Delete", "status"):
                    state.polls += 1
                    let done = state.polls > state.config.unfinishedPolls
                    let progress = done ? 1.0 : Double(state.polls) / Double(state.config.unfinishedPolls + 1)
                    return .data(Data(#"{"success":true,"data":{"finished":\#(done),"progress":\#(progress),"processed_num":\#(state.polls),"total":3}}"#.utf8))
                case ("SYNO.FileStation.CopyMove", "status"):
                    state.polls += 1
                    let done = state.polls > state.config.unfinishedPolls
                    let progress = done ? 1.0 : Double(state.polls) / Double(state.config.unfinishedPolls + 1)
                    return .data(Data(#"{"success":true,"data":{"finished":\#(done),"progress":\#(progress),"dest_folder_path":"/home"}}"#.utf8))
                case ("SYNO.Core.System", "shutdown"), ("SYNO.Core.User", "set"), ("SYNO.Core.Terminal", "set"),
                     ("SYNO.Core.Upgrade.Setting", "set"), ("SYNO.FileStation.CreateFolder", "create"),
                     ("SYNO.Backup.Task", "cancel"),
                     ("SYNO.Core.Share.Snapshot", "create"), ("SYNO.DR.Plan", "sync"):
                    return .data(Fixture.ok)
                case ("SYNO.Backup.Task", "backup"):
                    state.backupStarted = true
                    return .data(Fixture.ok)
                case ("SYNO.Backup.Task", "status"):
                    let offline = state.config.backupTargetsOffline.contains(params["task_id"] ?? "")
                    return .data(Data(#"{"success":true,"data":{"state":"backupable","status":"none","is_online":\#(!offline)}}"#.utf8))
                case ("SYNO.Backup.Task", "list") where state.backupStarted && state.config.backupFailsAfterStart:
                    let text = String(decoding: Fixture.data("backup_tasks"), as: UTF8.self)
                        .replacingOccurrences(of: #""last_bkp_time":"2026/11/08 03:00","next_bkp_time":"2026/11/09 03:00","last_bkp_result":"done""#,
                                              with: #""last_bkp_time":"2026/11/11 07:00","next_bkp_time":"2026/11/12 03:00","last_bkp_result":"fail""#)
                    return .data(Data(text.utf8))
                case ("SYNO.Core.Share.Snapshot", "list"):
                    // "home" lives on a volume without snapshot support.
                    return .data(params["name"] == "home" ? Fixture.error(400) : Fixture.data("snapshot_list"))
                case ("SYNO.DR.Plan", "list"):
                    return .data(Fixture.data("dr_plans"))
                case ("SYNO.Core.SecurityScan.Status", "system_get"):
                    return .data(Fixture.data(state.config.securityScanRunning ? "security_status_running" : "security_status"))
                case ("SYNO.Core.SecurityScan.Status", "rule_get"):
                    return .data(Fixture.data("security_rules"))
                case ("SYNO.Core.SecurityScan.Operation", "start"), ("SYNO.Core.SecurityScan.Operation", "specific_start"):
                    return .data(Fixture.ok)
                case ("SYNO.Virtualization.API.Guest.Action", "shutdown"), ("SYNO.Virtualization.API.Guest.Action", "poweroff"):
                    state.vmmLists = 0
                    state.vmmShutDown.insert((params["guest_id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    return .data(Fixture.ok)
                case ("SYNO.Virtualization.API.Guest.Action", "poweron"):
                    state.vmmShutDown.remove((params["guest_id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    return .data(Fixture.ok)
                case ("SYNO.Virtualization.API.Guest", "list"):
                    state.vmmLists += 1
                    var text = String(decoding: Fixture.data("vmm_guests"), as: UTF8.self)
                    if state.vmmLists > state.config.vmmStopsAfterLists {
                        for id in state.vmmShutDown {
                            text = text.replacingOccurrences(of: "\"guest_id\":\"\(id)\",\"guest_name\":\"homeassistant\",\"status\":\"running\"",
                                                             with: "\"guest_id\":\"\(id)\",\"guest_name\":\"homeassistant\",\"status\":\"shutdown\"")
                        }
                    }
                    return .data(Data(text.utf8))
                case ("SYNO.Core.System", "info") where params["type"] == "network":
                    return .data(Data(#"{"success":true,"data":{"nif":[{"id":"ovs_eth1","addr":"10.0.0.5","mask":"255.0.0.0","mac":"00:11:32:00:00:02","type":"lan"},{"id":"ovs_eth0","addr":"192.168.1.20","mask":"255.255.255.0","mac":"00-11-32-ab-cd-ef","type":"lan"}]}}"#.utf8))
                case ("SYNO.FileStation.List", "list_share"):
                    return .data(Fixture.data("file_shares"))
                case ("SYNO.FileStation.List", "list"):
                    return .data(Fixture.data("file_list"))
                case ("SYNO.Core.Package.Control", _), ("SYNO.Docker.Container", "start"), ("SYNO.Docker.Container", "stop"),
                     ("SYNO.Docker.Container", "restart"), ("SYNO.Docker.Project", "start"), ("SYNO.Docker.Project", "stop"),
                     ("SYNO.Docker.Project", "build"):
                    return .data(Fixture.ok)
                default:
                    break
                }
                let body: Data = switch api {
                case "SYNO.Core.System": Fixture.data("system_info")
                case "SYNO.Core.System.Utilization": Fixture.data("utilization")
                case "SYNO.Storage.CGI.Storage": Fixture.data("storage")
                case "SYNO.Entry.Request": Fixture.data("compound")
                case "SYNO.Core.Package": Fixture.data("packages")
                case "SYNO.Core.Package.Server": Fixture.data("server_packages")
                case "SYNO.Core.Upgrade.Server": Fixture.data("upgrade_check")
                case "SYNO.Core.SyslogClient.Log": Fixture.data("logs")
                case "SYNO.Docker.Container": Fixture.data("containers")
                case "SYNO.Docker.Container.Resource": Fixture.data("container_resources")
                case "SYNO.Docker.Container.Log": Fixture.data("container_logs")
                case "SYNO.Docker.Project": Fixture.data("projects")
                case "SYNO.Core.Upgrade.Setting": Fixture.data("upgrade_setting")
                case "SYNO.Core.User": Fixture.data("users")
                case "SYNO.Core.Terminal": Fixture.data("terminal")
                case "SYNO.Core.CurrentConnection": Fixture.data("connections")
                case "SYNO.Core.DSMNotify": Fixture.data("dsm_notify")
                case "SYNO.Backup.Task": Fixture.data("backup_tasks")
                case "SYNO.SDS.Backup.Client.Common.Log": Fixture.data("backup_log")
                default: Fixture.error(102)
                }
                return .delayed(body, state.config.dataLatency)
            }
        }

        switch outcome {
        case .data(let data): return data
        case .fail(let error): throw error
        case .delayed(let data, let latency):
            if latency > .zero { try await Task.sleep(for: latency) }
            return data
        }
    }
}

/// Collects backend events for assertions.
final class EventRecorder: Sendable {
    private let events = Mutex<[BackendEvent]>([])

    var all: [BackendEvent] { events.withLock { $0 } }

    func record(_ event: BackendEvent) {
        events.withLock { $0.append(event) }
    }
}

struct TestConnection {
    let connection: DSMConnection
    let transport: FakeDSM
    let credentials: InMemoryCredentialProvider
    let events: EventRecorder
    let profile: ServerProfile

    static func make(
        addresses: [ServerAddress] = [ServerAddress(host: "nas.lan", label: "LAN")],
        pinnedSPKI: String? = nil,
        password: String? = "s3cret+pass&word",
        deviceID: String? = nil,
        configuration: FakeDSM.Configuration = FakeDSM.Configuration(),
        rebootPolicy: DSMConnection.RebootPolicy = .instant
    ) async -> TestConnection {
        let profile = ServerProfile(name: "Test NAS", addresses: addresses, username: "nas-admin", pinnedSPKI: pinnedSPKI)
        let transport = FakeDSM(configuration)
        let credentials = InMemoryCredentialProvider()
        if let password {
            await credentials.set(ServerCredentials(password: password, deviceID: deviceID), for: profile.id)
        }
        let recorder = EventRecorder()
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        Task {
            for await event in stream { recorder.record(event) }
        }
        let connection = DSMConnection(profile: profile, transport: transport, credentials: credentials, deviceName: "NAS Cockpit Tests", events: continuation, rebootPolicy: rebootPolicy)
        return TestConnection(connection: connection, transport: transport, credentials: credentials, events: recorder, profile: profile)
    }
}

extension DSMConnection.RebootPolicy {
    /// No real waiting in tests.
    static var instant: Self {
        var policy = Self()
        policy.initialDelay = .milliseconds(1)
        policy.maxDelay = .milliseconds(1)
        policy.deadline = .seconds(5)
        policy.sleep = { _ in await Task.yield() }
        return policy
    }
}

/// A full `SynologyBackend` on top of `FakeDSM`, connected.
struct TestBackend {
    let backend: SynologyBackend
    let transport: FakeDSM
    let events: EventRecorder

    static func connected(
        configuration: FakeDSM.Configuration = FakeDSM.Configuration(),
        rebootPolicy: DSMConnection.RebootPolicy = .instant
    ) async throws -> TestBackend {
        let profile = ServerProfile(name: "Test NAS", addresses: [ServerAddress(host: "nas.lan", label: "LAN")], username: "nas-admin")
        let transport = FakeDSM(configuration)
        let credentials = InMemoryCredentialProvider()
        await credentials.set(ServerCredentials(password: "pw", deviceID: nil), for: profile.id)
        let backend = SynologyBackend(
            profile: profile, credentials: credentials, deviceName: "Tests", transport: transport,
            rebootPolicy: rebootPolicy, taskPollInterval: .milliseconds(1), taskDeadline: .seconds(5)
        )
        let recorder = EventRecorder()
        let events = backend.events
        Task {
            for await event in events { recorder.record(event) }
        }
        try await backend.connect(otp: nil)
        return TestBackend(backend: backend, transport: transport, events: recorder)
    }
}
