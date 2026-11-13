import Foundation
import Domain
import Networking

/// Runtime connection to one Proxmox VE host: address, ticket or token, the node that answers, state.
/// Isolated per host – a failing host only affects its own tile.
actor PVEConnection {
    static let probeTimeout: TimeInterval = 3
    /// Tickets last two hours; the connection renews one that is older than this before using it.
    static let ticketRenewalAge: TimeInterval = 60 * 60

    struct Policy: Sendable {
        var taskPollInterval: Duration = .seconds(2)
        var taskDeadline: Duration = .seconds(30 * 60)
        var rebootInitialDelay: Duration = .seconds(10)
        var rebootMaxDelay: Duration = .seconds(60)
        var rebootDeadline: Duration = .seconds(20 * 60)
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        static let standard = Policy()
    }

    private(set) var profile: ServerProfile
    private let transport: any HTTPTransport
    private let credentials: any CredentialProvider
    private let deviceName: String
    private let events: AsyncStream<BackendEvent>.Continuation
    private let openID: (any OpenIDAuthorizer)?
    let policy: Policy

    private(set) var activeAddress: ServerAddress?
    private var auth: PVEAuth?
    /// `user@realm` of the signed-in account (tokens: the user that owns the token).
    private(set) var signedInUser: String
    /// The node the active address belongs to. Dashboard, logs and updates are read from it.
    private(set) var localNode: String?
    private var reauthTask: Task<Void, Error>?
    private var reselectTask: Task<Void, Error>?
    private var isRebooting = false
    /// Half-ticket of a password login that still needs the TOTP code.
    private var pendingTFAChallenge: String?
    /// A user-driven connect may open the browser for OpenID; automatic ones never do.
    private(set) var allowsInteractiveSignIn = false

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if state != oldValue { events.yield(.state(state)) }
        }
    }

    init(
        profile: ServerProfile,
        transport: any HTTPTransport,
        credentials: any CredentialProvider,
        deviceName: String,
        openID: (any OpenIDAuthorizer)?,
        events: AsyncStream<BackendEvent>.Continuation,
        policy: Policy = .standard
    ) {
        self.profile = profile
        self.transport = transport
        self.credentials = credentials
        self.deviceName = deviceName
        self.openID = openID
        self.events = events
        self.policy = policy
        signedInUser = profile.username.split(separator: "!").first.map(String.init) ?? profile.username
    }

    func setInteractiveSignIn(_ allowed: Bool) {
        allowsInteractiveSignIn = allowed
    }

    /// After an API token was created for an OpenID account: later sign-ins use the token.
    func useAPIToken(_ tokenID: String) {
        profile.username = tokenID
    }

    var username: String { signedInUser }

    // MARK: Connect / disconnect

    func connect(otp: String?) async throws {
        state = .connecting
        do {
            if otp == nil || activeAddress == nil {
                try await selectAddress()
            }
            try await login(otp: otp, isReauthentication: false)
            await resolveLocalNode()
            state = .connected
        } catch {
            let mapped = PVEError.backendError(from: error)
            switch mapped {
            case .otpRequired, .otpInvalid:
                state = .needsOTP
            case .fingerprintChanged(_, let observed):
                let withExpected = BackendError.fingerprintChanged(expected: profile.pinnedSPKI ?? "", observed: observed)
                state = .failed(withExpected)
                throw withExpected
            default:
                state = .failed(mapped)
            }
            throw mapped
        }
    }

    /// Proxmox has no logout call; tickets simply expire.
    func disconnect() {
        auth = nil
        state = .disconnected
    }

    func markShutDown() {
        auth = nil
        state = .disconnected
    }

    func trust(_ certificate: CertificateInfo) {
        profile.pinnedSPKI = certificate.spkiSHA256
        transport.updatePinnedSPKI(certificate.spkiSHA256)
        events.yield(.pinned(spki: certificate.spkiSHA256))
    }

    /// The node to read host data from. Set after sign-in.
    func node() throws -> String {
        guard let localNode else { throw PVEError.notConnected }
        return localNode
    }

    // MARK: Calls

    func call<R: Decodable & Sendable>(_ endpoint: PVEEndpoint<R>) async throws -> R {
        try await callWithTotal(endpoint).value
    }

    func callWithTotal<R: Decodable & Sendable>(_ endpoint: PVEEndpoint<R>) async throws -> (value: R, total: Int?) {
        var didReauthenticate = false
        var didReselect = false

        while true {
            try await awaitRecovery()
            if isRebooting { throw PVEError.notConnected }
            guard let usedAuth = auth else { throw PVEError.notConnected }
            if case .ticket(_, _, let issued) = usedAuth, Date.now.timeIntervalSince(issued) > Self.ticketRenewalAge {
                // Best effort; an expired ticket is caught by the 401 path below.
                try? await renewTicket()
            }
            let current = auth ?? usedAuth

            do {
                return try await performWithTotal(endpoint, auth: current, isLogin: false)
            } catch let error as PVEError {
                if error == .sessionExpired {
                    // Tokens never expire: a 401 means the token was revoked.
                    guard current.isTicket else {
                        auth = nil
                        state = .failed(.invalidCredentials)
                        throw PVEError.auth(.invalidCredentials)
                    }
                    guard !didReauthenticate else {
                        auth = nil
                        state = .failed(.sessionLost)
                        throw PVEError.auth(.sessionLost)
                    }
                    didReauthenticate = true
                    if auth == current || auth == nil {
                        try await reauthenticate()
                    }
                    continue
                }
                if error.isConnectivityError, !didReselect, !endpoint.method.isWrite {
                    didReselect = true
                    try await reselectAddress()
                    continue
                }
                throw error
            }
        }
    }

    /// Polls a task until Proxmox reports it as stopped. Throws `taskFailed` with the exit status.
    func waitForTask(_ upid: PVEUPID, progress: @escaping ProgressHandler) async throws {
        let node: String
        if let upidNode = upid.node { node = upidNode } else { node = try self.node() }
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < policy.taskDeadline {
            let status = try await call(PVEEndpoints.Node.taskStatus(node, upid: upid.value))
            if status.isFinished {
                if status.succeeded { return }
                throw PVEError.taskFailed(status.exitstatus ?? String(localized: "The task failed."))
            }
            progress(nil)
            try await policy.sleep(policy.taskPollInterval)
        }
        throw PVEError.auth(.timeout)
    }

    /// After a reboot was accepted: wait until the host went down and answers again, then sign in again.
    func awaitReboot() async throws {
        isRebooting = true
        state = .rebooting
        defer { isRebooting = false }

        let clock = ContinuousClock()
        let start = clock.now
        var delay = policy.rebootInitialDelay
        var wentDown = false
        while clock.now - start < policy.rebootDeadline {
            do {
                try await policy.sleep(delay)
            } catch {
                state = .failed(.cancelled)
                throw PVEError.auth(.cancelled)
            }
            delay = min(policy.rebootMaxDelay, delay * 1.5)
            guard let address = activeAddress else { break }
            guard await Self.probe(address, transport: transport) == .reachable else {
                wentDown = true
                continue
            }
            guard wentDown else { continue }
            auth = nil
            do {
                try await login(otp: nil, isReauthentication: true)
                state = .connected
                return
            } catch {
                let mapped = PVEError.backendError(from: error)
                if mapped.isAuthenticationFailure {
                    state = .failed(mapped)
                    throw PVEError.auth(mapped)
                }
                continue
            }
        }
        auth = nil
        state = .failed(.rebootTimeout)
        throw PVEError.auth(.rebootTimeout)
    }

    // MARK: Tokens

    /// Creates an API token for the signed-in user (allowed for one's own account). Returns the full token
    /// ID (`user@realm!name`) and the secret, which Proxmox shows exactly once.
    func createAPIToken(name: String) async throws -> (tokenID: String, secret: String) {
        let comment = "NAS Cockpit (\(deviceName))"
        let created = try await call(PVEEndpoints.Access.createToken(user: signedInUser, name: name, comment: comment))
        guard let id = created.fullTokenID, let secret = created.value else { throw PVEError.invalidResponse }
        return (id, secret)
    }

    // MARK: Recovery

    private func awaitRecovery() async throws {
        if let reauthTask { try await reauthTask.value }
        if let reselectTask { try await reselectTask.value }
    }

    private func reauthenticate() async throws {
        if let reauthTask { return try await reauthTask.value }
        let task = Task { try await self.runReauthentication() }
        reauthTask = task
        defer { reauthTask = nil }
        try await task.value
    }

    private func runReauthentication() async throws {
        state = .reauthenticating
        auth = nil
        do {
            try await login(otp: nil, isReauthentication: true)
            state = .connected
        } catch {
            let mapped = PVEError.backendError(from: error)
            // A TOTP prompt during re-login cannot be answered here: the user has to reconnect.
            let final: BackendError = (mapped == .otpRequired || mapped == .otpInvalid) ? .sessionLost : mapped
            state = .failed(final)
            throw PVEError.auth(final)
        }
    }

    private func renewTicket() async throws {
        guard case .ticket(let ticket, _, _) = auth else { return }
        let response = try await perform(PVEEndpoints.Access.renew(username: signedInUser, ticket: ticket), auth: nil, isLogin: true)
        guard let newTicket = response.ticket, let csrf = response.csrf else { throw PVEError.invalidResponse }
        auth = .ticket(newTicket, csrf: csrf, issued: .now)
    }

    private func reselectAddress() async throws {
        if let reselectTask { return try await reselectTask.value }
        let task = Task { try await self.runReselect() }
        reselectTask = task
        defer { reselectTask = nil }
        try await task.value
    }

    private func runReselect() async throws {
        do {
            try await selectAddress()
        } catch {
            auth = nil
            state = .failed(PVEError.backendError(from: error))
            throw error
        }
    }

    // MARK: Steps

    private func selectAddress() async throws {
        let transport = self.transport
        let resolver = AddressResolver { address in
            await PVEConnection.probe(address, transport: transport)
        }
        switch await resolver.resolve(profile.addresses, lastReachedID: profile.lastReachedAddressID) {
        case .selected(let address):
            activeAddress = address
            if profile.lastReachedAddressID != address.id {
                profile.lastReachedAddressID = address.id
            }
            events.yield(.addressReached(address.id))
        case .needsTrust(_, let info):
            throw PVEError.auth(.certificateUntrusted(info))
        case .fingerprintChanged(let observed):
            throw PVEError.auth(.fingerprintChanged(expected: profile.pinnedSPKI ?? "", observed: observed))
        case .unreachable:
            throw PVEError.auth(.unreachable)
        }
    }

    /// Unauthenticated `GET /access/domains` with a short timeout: confirms TLS and that Proxmox answers.
    static func probe(_ address: ServerAddress, transport: any HTTPTransport) async -> ProbeOutcome {
        let endpoint = PVEEndpoints.Access.domains
        guard let request = try? PVERequestBuilder.request(
            address: address, method: endpoint.method, path: endpoint.path, params: endpoint.params, auth: nil, timeout: probeTimeout
        ) else { return .unreachable }
        do {
            let response = try await transport.fetch(request)
            guard response.isSuccess, (try? PVEDecoding.decode(response.body, as: [DomainDTO].self)) != nil else { return .unreachable }
            return .reachable
        } catch TransportError.untrustedCertificate(let info) {
            return .untrusted(info)
        } catch TransportError.fingerprintMismatch(let info) {
            return .mismatch(info)
        } catch {
            return .unreachable
        }
    }

    /// Realms the host offers (for the OpenID picker in the add-server flow). Needs no sign-in.
    func realms() async throws -> [DomainDTO] {
        if activeAddress == nil { try await selectAddress() }
        return try await perform(PVEEndpoints.Access.domains, auth: nil, isLogin: false)
    }

    private func login(otp: String?, isReauthentication: Bool) async throws {
        var usedOTP = false
        switch profile.authMethod {
        case .apiToken:
            try await loginWithToken()
        case .password:
            usedOTP = try await loginWithPassword(otp: otp)
        case .openID(let realm):
            if profile.hasAPIToken {
                try await loginWithToken()
            } else if allowsInteractiveSignIn, !isReauthentication, let openID {
                try await loginWithOpenID(realm: realm, authorizer: openID)
            } else {
                throw PVEError.auth(.openIDSignInRequired)
            }
        }
        events.yield(.loggedIn(LoginInfo(usedOTP: usedOTP, hasDeviceToken: profile.hasAPIToken, isReauthentication: isReauthentication)))
    }

    private func storedCredentials() async throws -> ServerCredentials {
        let stored: ServerCredentials?
        do {
            stored = try await credentials.credentials(for: profile.id)
        } catch {
            throw PVEError.auth(.credentialsUnavailable)
        }
        guard let stored else { throw PVEError.auth(.passwordRequired) }
        return stored
    }

    /// `Authorization: PVEAPIToken=user@realm!name=secret`, verified with a cheap read.
    private func loginWithToken() async throws {
        let stored = try await storedCredentials()
        let token = PVEAuth.token("\(profile.username)=\(stored.password)")
        do {
            _ = try await perform(PVEEndpoints.version, auth: token, isLogin: false)
        } catch PVEError.sessionExpired {
            throw PVEError.auth(.invalidCredentials)
        } catch PVEError.permissionDenied {
            throw PVEError.auth(.permissionDenied)
        }
        auth = token
        signedInUser = profile.username.split(separator: "!").first.map(String.init) ?? profile.username
    }

    /// Returns whether a TOTP code was used.
    private func loginWithPassword(otp: String?) async throws -> Bool {
        let stored = try await storedCredentials()
        let response: TicketDTO
        var usedOTP = false
        if let otp, let challenge = pendingTFAChallenge {
            do {
                response = try await perform(PVEEndpoints.Access.loginTFA(username: profile.username, challenge: challenge, code: otp), auth: nil, isLogin: true)
            } catch PVEError.auth(.invalidCredentials) {
                throw PVEError.auth(.otpInvalid)
            }
            usedOTP = true
        } else {
            response = try await perform(PVEEndpoints.Access.login(username: profile.username, password: stored.password), auth: nil, isLogin: true)
            if response.needTFA?.boolValue == true, let challenge = response.ticket {
                pendingTFAChallenge = challenge
                throw PVEError.auth(.otpRequired)
            }
        }
        pendingTFAChallenge = nil
        try adopt(response)
        return usedOTP
    }

    private func loginWithOpenID(realm: String, authorizer: any OpenIDAuthorizer) async throws {
        let authURL = try await perform(PVEEndpoints.Access.openIDAuthURL(realm: realm, redirectURL: OpenIDRedirect.url), auth: nil, isLogin: true)
        guard let url = URL(string: authURL.url) else { throw PVEError.invalidResponse }
        let callback: URL
        do {
            callback = try await authorizer.authorize(url: url, callbackScheme: OpenIDRedirect.scheme)
        } catch is CancellationError {
            throw PVEError.auth(.cancelled)
        } catch {
            throw PVEError.auth(.operationFailed(error.localizedDescription))
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, let state = items.first(where: { $0.name == "state" })?.value else {
            throw PVEError.auth(.operationFailed(String(localized: "The identity provider did not return an authorization code.")))
        }
        let response = try await perform(PVEEndpoints.Access.openIDLogin(code: code, state: state, redirectURL: OpenIDRedirect.url), auth: nil, isLogin: true)
        try adopt(response)
    }

    private func adopt(_ response: TicketDTO) throws {
        guard let ticket = response.ticket, let csrf = response.csrf else { throw PVEError.invalidResponse }
        auth = .ticket(ticket, csrf: csrf, issued: .now)
        if let username = response.username, !username.isEmpty { signedInUser = username }
    }

    private func resolveLocalNode() async {
        if let status = try? await call(PVEEndpoints.Cluster.status),
           let local = status.first(where: { $0.type == "node" && ($0.local?.boolValue ?? false) })?.name {
            localNode = local
        } else if let nodes = try? await call(PVEEndpoints.Cluster.nodes),
                  let first = nodes.first(where: { $0.status == "online" }) ?? nodes.first {
            localNode = first.node
        } else if let host = activeAddress?.host.split(separator: ".").first {
            localNode = String(host)
        }
    }

    // MARK: Transport

    private func perform<R: Decodable & Sendable>(_ endpoint: PVEEndpoint<R>, auth: PVEAuth?, isLogin: Bool) async throws -> R {
        try await performWithTotal(endpoint, auth: auth, isLogin: isLogin).value
    }

    private func performWithTotal<R: Decodable & Sendable>(_ endpoint: PVEEndpoint<R>, auth: PVEAuth?, isLogin: Bool) async throws -> (value: R, total: Int?) {
        guard let address = activeAddress else { throw PVEError.notConnected }
        let request = try PVERequestBuilder.request(
            address: address, method: endpoint.method, path: endpoint.path, params: endpoint.params, auth: auth, timeout: endpoint.timeout
        )
        let response: HTTPResponse
        do {
            response = try await transport.fetch(request)
        } catch let error as TransportError {
            throw PVEError.transport(error)
        } catch {
            throw PVEError.transport(.unreachable)
        }
        guard response.isSuccess else {
            let message = PVEDecoding.errorMessage(response.body) ?? ""
            switch response.status {
            case 401: throw isLogin ? PVEError.auth(.invalidCredentials) : PVEError.sessionExpired
            case 403: throw isLogin ? PVEError.auth(.permissionDenied) : PVEError.permissionDenied
            default: throw PVEError.http(status: response.status, message: message)
            }
        }
        return try PVEDecoding.decode(response.body, as: R.self)
    }
}
