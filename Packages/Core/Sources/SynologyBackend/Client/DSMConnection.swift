import Foundation
import Domain
import Networking

/// Runtime connection to one NAS: session (`sid`, SynoToken), active address, API catalog
/// and state. Isolated per NAS – a failing NAS only affects its own tile.
actor DSMConnection {
    static let probeTimeout: TimeInterval = 3

    /// How the connection waits for a NAS that restarts (DSM update, reboot).
    struct RebootPolicy: Sendable {
        /// First wait before the first probe.
        var initialDelay: Duration = .seconds(10)
        /// Each wait is multiplied by this, up to `maxDelay`.
        var multiplier: Double = 1.5
        var maxDelay: Duration = .seconds(60)
        /// Give up after this long (DSM updates can take a while on slow disks).
        var deadline: Duration = .seconds(45 * 60)
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        static let standard = RebootPolicy()
    }

    private(set) var profile: ServerProfile
    private let transport: any HTTPTransport
    private let credentials: any CredentialProvider
    private let deviceName: String
    private let events: AsyncStream<BackendEvent>.Continuation
    private let rebootPolicy: RebootPolicy

    private(set) var activeAddress: ServerAddress?
    private(set) var catalog: APICatalog?
    private var session: DSMSession?
    private var reauthTask: Task<Void, Error>?
    private var reselectTask: Task<Void, Error>?
    /// Set on 407 (Auto Block). Nothing is sent until the user explicitly reconnects.
    private var isBlocked = false
    /// While the NAS restarts, normal calls fail fast with `notConnected`.
    private var isRebooting = false

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
        events: AsyncStream<BackendEvent>.Continuation,
        rebootPolicy: RebootPolicy = .standard
    ) {
        self.profile = profile
        self.transport = transport
        self.credentials = credentials
        self.deviceName = deviceName
        self.events = events
        self.rebootPolicy = rebootPolicy
    }

    var capabilities: Set<Capability> {
        guard let catalog else { return [] }
        var found = Set(DSMEndpoints.capabilityAPIs.compactMap { catalog.supports($0.1) ? $0.0 : nil })
        let controlPanel: Set<Capability> = [.updateSettings, .users, .terminal, .power, .connections]
        if !found.isDisjoint(with: controlPanel) { found.insert(.settings) }
        return found
    }

    var username: String { profile.username }

    // MARK: Connect / disconnect

    /// User-initiated connect. Throws `BackendError`.
    func connect(otp: String?) async throws {
        isBlocked = false
        state = .connecting
        do {
            // On an OTP retry the address and catalog from the first attempt are still valid.
            if otp == nil || activeAddress == nil {
                try await selectAddress()
            }
            if catalog == nil {
                try await loadCatalog()
            }
            try await login(otp: otp, isReauthentication: false)
            state = .connected
        } catch {
            let mapped = DSMError.backendError(from: error)
            switch mapped {
            case .otpRequired, .otpInvalid:
                state = .needsOTP
            case .ipBlocked:
                isBlocked = true
                state = .failed(mapped)
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

    func disconnect() async {
        if let session {
            _ = try? await perform(DSMEndpoints.Auth.logout, session: session)
        }
        session = nil
        state = .disconnected
    }

    /// After a shutdown was accepted: forget the session without trying to log out.
    func markShutDown() {
        session = nil
        state = .disconnected
    }

    /// TOFU: the user confirmed the fingerprint. Pins the public key for this NAS.
    func trust(_ certificate: CertificateInfo) {
        profile.pinnedSPKI = certificate.spkiSHA256
        profile.trustedCertificateName = certificate.publicName
        transport.updatePin(spki: certificate.spkiSHA256, trustedName: certificate.publicName)
        events.yield(.pinned(spki: certificate.spkiSHA256, name: certificate.publicName))
    }

    // MARK: Calls

    func call<R: Decodable & Sendable>(_ endpoint: DSMEndpoint<R>) async throws -> R {
        var didReauthenticate = false
        var didReselect = false

        while true {
            try await awaitRecovery()
            if isBlocked { throw DSMError.auth(.ipBlocked) }
            if isRebooting { throw DSMError.notConnected }
            guard let usedSession = session else { throw DSMError.notConnected }

            do {
                return try await perform(endpoint, session: usedSession)
            } catch let error as DSMError {
                if error.isSessionError {
                    // At most one re-login per request, never a loop (DSM Auto Block).
                    guard !didReauthenticate else {
                        session = nil
                        state = .failed(.sessionLost)
                        throw DSMError.auth(.sessionLost)
                    }
                    didReauthenticate = true
                    if error == .sessionInterrupted { events.yield(.sessionInterrupted) }
                    // Another request may already have renewed the session.
                    if session == usedSession || session == nil {
                        try await reauthenticate()
                    }
                    continue
                }
                if error.isConnectivityError, !didReselect, !endpoint.isWrite {
                    didReselect = true
                    try await reselectAddress()
                    continue
                }
                throw error
            }
        }
    }

    /// Several reads in one request via `SYNO.Entry.Request`. APIs missing on the NAS are skipped.
    func compound(_ items: [CompoundItem]) async throws -> [CompoundResult] {
        guard let catalog else { throw DSMError.notConnected }
        var entries: [[String: Any]] = []
        for item in items {
            guard let (_, version) = try? catalog.resolve(api: item.api, versions: item.versions) else { continue }
            var entry: [String: Any] = ["api": item.api, "method": item.method, "version": version]
            for (key, value) in item.params { entry[key] = value }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return [] }
        let json = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        let response = try await call(DSMEndpoints.Entry.request(compound: String(decoding: json, as: UTF8.self)))
        return response.result
    }

    // MARK: Reboot

    /// Called after DSM accepted an update/reboot. Waits until the NAS went down and answers again
    /// (growing interval), then signs in again automatically. The tile shows `.rebooting` meanwhile.
    ///
    /// "Back" means: the probe failed at least once and then succeeds, or a probe succeeds but the old
    /// session is gone (reboot between two probes).
    func awaitReboot() async throws {
        isRebooting = true
        state = .rebooting
        let oldSession = session
        defer { isRebooting = false }

        let clock = ContinuousClock()
        let start = clock.now
        var delay = rebootPolicy.initialDelay
        var wentDown = false

        while clock.now - start < rebootPolicy.deadline {
            do {
                try await rebootPolicy.sleep(delay)
            } catch {
                state = .failed(.cancelled)
                throw DSMError.auth(.cancelled)
            }
            delay = min(rebootPolicy.maxDelay, delay * rebootPolicy.multiplier)

            guard let address = activeAddress else { break }
            let reachable = await DSMConnection.probe(address, transport: transport) == .reachable
            guard reachable else {
                wentDown = true
                continue
            }
            if !wentDown, let oldSession, await isSessionValid(oldSession) {
                continue // still installing, not restarted yet
            }

            session = nil
            catalog = nil
            do {
                try await loadCatalog()
                try await login(otp: nil, isReauthentication: true)
                state = .connected
                return
            } catch {
                let mapped = DSMError.backendError(from: error)
                switch mapped {
                case .ipBlocked:
                    isBlocked = true
                    state = .failed(mapped)
                    throw DSMError.auth(mapped)
                case .invalidCredentials, .accountDisabled, .permissionDenied, .passwordExpired,
                     .twoFactorSetupRequired, .credentialsUnavailable, .passwordRequired:
                    state = .failed(mapped)
                    throw DSMError.auth(mapped)
                case .otpRequired, .otpInvalid:
                    state = .failed(.sessionLost)
                    throw DSMError.auth(.sessionLost)
                default:
                    // DSM answers the probe before all services are up; keep waiting.
                    wentDown = true
                    continue
                }
            }
        }
        session = nil
        state = .failed(.rebootTimeout)
        throw DSMError.auth(.rebootTimeout)
    }

    /// Cheap authenticated read without re-login. A session error means DSM restarted.
    private func isSessionValid(_ session: DSMSession) async -> Bool {
        do {
            _ = try await perform(DSMEndpoints.System.info, session: session)
            return true
        } catch let error as DSMError where error.isSessionError {
            return false
        } catch {
            return true
        }
    }

    // MARK: Recovery

    private func awaitRecovery() async throws {
        if let reauthTask { try await reauthTask.value }
        if let reselectTask { try await reselectTask.value }
    }

    /// All waiting requests share one re-login task.
    private func reauthenticate() async throws {
        if let reauthTask { return try await reauthTask.value }
        let task = Task { try await self.runReauthentication() }
        reauthTask = task
        defer { reauthTask = nil }
        try await task.value
    }

    private func runReauthentication() async throws {
        state = .reauthenticating
        session = nil
        do {
            try await login(otp: nil, isReauthentication: true)
            state = .connected
        } catch {
            let mapped = DSMError.backendError(from: error)
            if mapped == .ipBlocked { isBlocked = true }
            // An OTP prompt during re-login means the device token is gone: the user has to reconnect.
            let final: BackendError = (mapped == .otpRequired || mapped == .otpInvalid) ? .sessionLost : mapped
            state = .failed(final)
            throw DSMError.auth(final)
        }
    }

    /// Connection dropped: run the address selection once more before giving up.
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
            session = nil
            state = .failed(DSMError.backendError(from: error))
            throw error
        }
    }

    // MARK: Steps

    private func selectAddress() async throws {
        let transport = self.transport
        let resolver = AddressResolver { address in
            await DSMConnection.probe(address, transport: transport)
        }
        switch await resolver.resolve(profile.addresses, lastReachedID: profile.lastReachedAddressID) {
        case .selected(let address):
            activeAddress = address
            if profile.lastReachedAddressID != address.id {
                profile.lastReachedAddressID = address.id
            }
            events.yield(.addressReached(address.id))
        case .needsTrust(_, let info):
            throw DSMError.auth(.certificateUntrusted(info))
        case .fingerprintChanged(let observed):
            throw DSMError.auth(.fingerprintChanged(expected: profile.pinnedSPKI ?? "", observed: observed))
        case .unreachable:
            throw DSMError.auth(.unreachable)
        }
    }

    /// Unauthenticated `SYNO.API.Info` call with a short timeout. Confirms TLS and that DSM answers.
    static func probe(_ address: ServerAddress, transport: any HTTPTransport) async -> ProbeOutcome {
        let params = ["api": DSMEndpoints.Info.api, "version": "1", "method": "query", "query": DSMEndpoints.Auth.api]
        guard let request = try? DSMRequestBuilder.request(
            address: address, path: DSMEndpoints.Info.path, params: params,
            isWrite: false, timeout: probeTimeout, session: nil
        ) else { return .unreachable }
        do {
            let data = try await transport.send(request)
            return (try? JSONDecoder().decode(DSMStatus.self, from: data)) != nil ? .reachable : .unreachable
        } catch TransportError.untrustedCertificate(let info) {
            return .untrusted(info)
        } catch TransportError.fingerprintMismatch(let info) {
            return .mismatch(info)
        } catch {
            return .unreachable
        }
    }

    private func loadCatalog() async throws {
        let params = ["api": DSMEndpoints.Info.api, "version": "1", "method": "query", "query": "all"]
        let request = try makeRequest(path: DSMEndpoints.Info.path, params: params, isWrite: false, timeout: 10, session: nil)
        let data = try await sendRaw(request)
        let entries = try DSMDecoding.decode(data, api: DSMEndpoints.Info.api, as: [String: APICatalog.Entry].self)
        catalog = APICatalog(entries: entries)
    }

    private func login(otp: String?, isReauthentication: Bool) async throws {
        let stored: ServerCredentials?
        do {
            stored = try await credentials.credentials(for: profile.id)
        } catch {
            throw DSMError.auth(.credentialsUnavailable)
        }
        guard let stored else { throw DSMError.auth(.passwordRequired) }

        var params: [String: String] = [
            "account": profile.username,
            "passwd": stored.password,
            "format": "sid",
            "enable_syno_token": "yes",
            // TODO(verify): confirm which session name gives access to SYNO.Core.* on DSM 7.2.
            "session": "webui",
        ]
        if let otp {
            params["otp_code"] = otp
            params["enable_device_token"] = "yes"
            params["device_name"] = deviceName
        } else if let deviceID = stored.deviceID {
            params["device_id"] = deviceID
            params["device_name"] = deviceName
        }

        let response = try await perform(DSMEndpoints.Auth.login(params), session: nil)
        session = DSMSession(sid: response.sid, synoToken: response.synoToken)

        if let newDeviceID = response.deviceID, newDeviceID != stored.deviceID {
            try? await credentials.storeDeviceID(newDeviceID, for: profile.id)
        }
        events.yield(.loggedIn(LoginInfo(
            usedOTP: otp != nil,
            hasDeviceToken: (response.deviceID ?? stored.deviceID) != nil,
            isReauthentication: isReauthentication
        )))
    }

    // MARK: Transport

    private func perform<R: Decodable & Sendable>(_ endpoint: DSMEndpoint<R>, session: DSMSession?) async throws -> R {
        guard let catalog else { throw DSMError.notConnected }
        let (path, version) = try catalog.resolve(api: endpoint.api, versions: endpoint.versions)
        var params = endpoint.params
        params["api"] = endpoint.api
        params["version"] = String(version)
        params["method"] = endpoint.method
        let request = try makeRequest(path: path, params: params, isWrite: endpoint.isWrite, timeout: endpoint.timeout, session: session)
        let data = try await sendRaw(request)
        return try DSMDecoding.decode(data, api: endpoint.api, as: R.self)
    }

    private func makeRequest(path: String, params: [String: String], isWrite: Bool, timeout: TimeInterval, session: DSMSession?) throws -> URLRequest {
        guard let address = activeAddress else { throw DSMError.notConnected }
        return try DSMRequestBuilder.request(address: address, path: path, params: params, isWrite: isWrite, timeout: timeout, session: session)
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        do {
            return try await transport.send(request)
        } catch let error as TransportError {
            throw DSMError.transport(error)
        } catch {
            throw DSMError.transport(.unreachable)
        }
    }
}
