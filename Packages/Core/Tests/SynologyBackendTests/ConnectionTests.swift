import Foundation
import Testing
import Domain
import Networking
@testable import SynologyBackend

@Suite("DSM connection")
struct ConnectionTests {
    @Test func probesBeforeSendingCredentials() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)

        let requests = test.transport.requests
        let firstLogin = try #require(requests.firstIndex { $0.params["method"] == "login" })
        let probe = try #require(requests.firstIndex { $0.params["query"] == DSMEndpoints.Auth.api })
        #expect(probe < firstLogin)
        #expect(await test.connection.state == .connected)
    }

    @Test func passwordIsSentInPostBodyNeverInURL() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)

        let login = try #require(test.transport.requests.first { $0.params["method"] == "login" })
        #expect(login.method == "POST")
        #expect(login.params["passwd"] == "s3cret+pass&word")
        #expect(login.urlQuery == nil)
        for request in test.transport.requests {
            #expect(!(request.urlQuery ?? "").contains("passwd"))
        }
    }

    @Test func authenticatedReadsCarrySIDAndPickHighestCommonVersion() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)
        _ = try await test.connection.call(DSMEndpoints.Packages.installed)

        let request = try #require(test.transport.dataRequests.last)
        #expect(request.method == "GET")
        #expect(request.params["_sid"] == "sid-1")
        #expect(request.params["version"] == "2")
    }

    @Test func otpFlowStoresDeviceToken() async throws {
        var config = FakeDSM.Configuration()
        config.loginResults = [.error(403)]
        let test = await TestConnection.make(configuration: config)

        await #expect(throws: BackendError.otpRequired) {
            try await test.connection.connect(otp: nil)
        }
        #expect(await test.connection.state == .needsOTP)

        try await test.connection.connect(otp: "123456")
        let login = try #require(test.transport.requests.last { $0.params["method"] == "login" })
        #expect(login.params["otp_code"] == "123456")
        #expect(login.params["enable_device_token"] == "yes")
        #expect(login.params["device_name"] == "NAS Cockpit Tests")
        #expect(await test.credentials.credentials(for: test.profile.id)?.deviceID == "device-123")
    }

    @Test func laterLoginsSendDeviceIDWithoutOTP() async throws {
        let test = await TestConnection.make(deviceID: "known-device")
        try await test.connection.connect(otp: nil)
        let login = try #require(test.transport.requests.first { $0.params["method"] == "login" })
        #expect(login.params["device_id"] == "known-device")
        #expect(login.params["otp_code"] == nil)
    }

    @Test func wrongOTPAsksAgain() async throws {
        var config = FakeDSM.Configuration()
        config.loginResults = [.error(403), .error(404)]
        let test = await TestConnection.make(configuration: config)
        await #expect(throws: BackendError.otpRequired) { try await test.connection.connect(otp: nil) }
        await #expect(throws: BackendError.otpInvalid) { try await test.connection.connect(otp: "000000") }
        #expect(await test.connection.state == .needsOTP)
    }

    @Test func parallelRequestsShareOneRelogin() async throws {
        var config = FakeDSM.Configuration()
        config.expiredSIDs = ["sid-1"]
        config.dataLatency = .milliseconds(20)
        let test = await TestConnection.make(configuration: config)
        try await test.connection.connect(otp: nil)
        #expect(test.transport.loginCount == 1)

        let connection = test.connection
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<5 {
                group.addTask {
                    (try? await connection.call(DSMEndpoints.System.info)) != nil
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results == Array(repeating: true, count: 5))
        #expect(test.transport.loginCount == 2)
        #expect(await connection.state == .connected)
    }

    @Test func atMostOneReloginPerRequest() async throws {
        var config = FakeDSM.Configuration()
        config.alwaysExpire = true
        let test = await TestConnection.make(configuration: config)
        try await test.connection.connect(otp: nil)

        await #expect(throws: DSMError.auth(.sessionLost)) {
            try await test.connection.call(DSMEndpoints.System.info)
        }
        #expect(test.transport.loginCount == 2)
        #expect(await test.connection.state == .failed(.sessionLost))
    }

    @Test func failedReloginStopsInsteadOfLooping() async throws {
        var config = FakeDSM.Configuration()
        config.expiredSIDs = ["sid-1"]
        config.loginResults = [.success, .error(400)]
        let test = await TestConnection.make(configuration: config)
        try await test.connection.connect(otp: nil)

        await #expect(throws: DSMError.auth(.invalidCredentials)) {
            try await test.connection.call(DSMEndpoints.System.info)
        }
        // Further calls do not trigger more logins.
        _ = try? await test.connection.call(DSMEndpoints.System.info)
        #expect(test.transport.loginCount == 2)
        #expect(await test.connection.state == .failed(.invalidCredentials))
    }

    @Test func autoBlockStopsAllRetries() async throws {
        var config = FakeDSM.Configuration()
        config.loginResults = [.error(407)]
        let test = await TestConnection.make(configuration: config)

        await #expect(throws: BackendError.ipBlocked) { try await test.connection.connect(otp: nil) }
        let requestCount = test.transport.requests.count

        await #expect(throws: DSMError.auth(.ipBlocked)) {
            try await test.connection.call(DSMEndpoints.System.info)
        }
        #expect(test.transport.requests.count == requestCount)
        #expect(test.transport.loginCount == 1)
    }

    @Test func missingPasswordAsksUser() async throws {
        let test = await TestConnection.make(password: nil)
        await #expect(throws: BackendError.passwordRequired) { try await test.connection.connect(otp: nil) }
        #expect(test.transport.loginCount == 0)
    }

    @Test func foreignFingerprintReportsPinnedValue() async throws {
        let observed = CertificateInfo(spkiSHA256: "new", certificateSHA256: "c", subject: "nas")
        var config = FakeDSM.Configuration()
        config.hostErrors = ["nas.lan": .fingerprintMismatch(observed: observed)]
        let test = await TestConnection.make(pinnedSPKI: "old", configuration: config)

        await #expect(throws: BackendError.fingerprintChanged(expected: "old", observed: observed)) {
            try await test.connection.connect(otp: nil)
        }
        #expect(test.transport.loginCount == 0)
    }

    @Test func untrustedCertificateNeedsConfirmationBeforeLogin() async throws {
        let observed = CertificateInfo(spkiSHA256: "abc", certificateSHA256: "c", subject: "nas")
        var config = FakeDSM.Configuration()
        config.hostErrors = ["nas.lan": .untrustedCertificate(observed)]
        let test = await TestConnection.make(configuration: config)

        await #expect(throws: BackendError.certificateUntrusted(observed)) {
            try await test.connection.connect(otp: nil)
        }
        #expect(test.transport.loginCount == 0)
    }

    @Test func skipsAddressWithForeignFingerprint() async throws {
        let lan = ServerAddress(host: "192.168.1.10", label: "LAN")
        let vpn = ServerAddress(host: "100.64.0.10", label: "Tailscale")
        var config = FakeDSM.Configuration()
        config.hostErrors = [lan.host: .fingerprintMismatch(observed: CertificateInfo(spkiSHA256: "x", certificateSHA256: "y", subject: "hotel"))]
        let test = await TestConnection.make(addresses: [lan, vpn], pinnedSPKI: "pinned", configuration: config)

        try await test.connection.connect(otp: nil)
        #expect(await test.connection.activeAddress == vpn)
        let login = try #require(test.transport.requests.first { $0.params["method"] == "login" })
        #expect(login.host == vpn.host)
    }

    @Test func reselectsAddressOnceWhenConnectionDrops() async throws {
        let lan = ServerAddress(host: "192.168.1.10", label: "LAN")
        let vpn = ServerAddress(host: "100.64.0.10", label: "Tailscale")
        let test = await TestConnection.make(addresses: [lan, vpn])
        try await test.connection.connect(otp: nil)
        #expect(await test.connection.activeAddress == lan)

        test.transport.configure { $0.hostErrors = [lan.host: .timeout] }
        _ = try await test.connection.call(DSMEndpoints.System.info)

        #expect(await test.connection.activeAddress == vpn)
        #expect(test.transport.loginCount == 1)
    }

    @Test func goesToFailedWhenNoAddressAnswersAfterDrop() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)
        test.transport.configure { $0.hostErrors = ["nas.lan": .unreachable] }

        await #expect(throws: DSMError.auth(.unreachable)) {
            try await test.connection.call(DSMEndpoints.System.info)
        }
        #expect(await test.connection.state == .failed(.unreachable))
    }

    @Test func writesAreNotRetriedAfterConnectionDrop() async throws {
        let lan = ServerAddress(host: "192.168.1.10", label: "LAN")
        let vpn = ServerAddress(host: "100.64.0.10", label: "Tailscale")
        let test = await TestConnection.make(addresses: [lan, vpn])
        try await test.connection.connect(otp: nil)
        test.transport.configure { $0.hostErrors = [lan.host: .timeout] }

        let write = DSMEndpoint<EmptyResponse>(api: "SYNO.Core.Package", method: "start", versions: 1...2, isWrite: true)
        await #expect(throws: DSMError.transport(.timeout)) {
            try await test.connection.call(write)
        }
        #expect(test.transport.requests.filter { $0.params["method"] == "start" }.count == 1)
    }

    @Test func capabilitiesFollowTheCatalog() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)
        let capabilities = await test.connection.capabilities
        #expect(capabilities.isSuperset(of: [.dashboard, .packages, .systemUpdate, .logs, .files, .containers, .vms]))
    }

    @Test func missingAPIIsUnsupportedNotAnError() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)
        let docker = DSMEndpoint<EmptyResponse>(api: "SYNO.Virtualization.Guest", method: "list", versions: 1...1)
        await #expect(throws: DSMError.unsupported("SYNO.Virtualization.Guest")) {
            try await test.connection.call(docker)
        }
        #expect(DSMError.backendError(from: DSMError.unsupported("x")) == .notSupported)
    }

    @Test func emitsLastReachedAddress() async throws {
        let test = await TestConnection.make()
        try await test.connection.connect(otp: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.events.all.contains(.addressReached(test.profile.addresses[0].id)))
        #expect(test.events.all.contains(.state(.connected)))
    }
}

@Suite("Synology backend")
struct SynologyBackendTests {
    @Test func snapshotUsesSingleCompoundRequest() async throws {
        let transport = FakeDSM()
        let profile = ServerProfile(name: "NAS", addresses: [ServerAddress(host: "nas.lan")], username: "nas-admin")
        let credentials = InMemoryCredentialProvider()
        await credentials.set(ServerCredentials(password: "pw"), for: profile.id)
        let backend = SynologyBackend(profile: profile, credentials: credentials, deviceName: "Tests", transport: transport)

        try await backend.connect(otp: nil)
        let snapshot = try await backend.systemSnapshot()

        #expect(transport.dataRequests.count == 1)
        #expect(transport.dataRequests.first?.params["api"] == "SYNO.Entry.Request")
        #expect(snapshot.model == "DS920+")
        #expect(snapshot.volumes.count == 2)
    }

    @Test func updatesCombineDSMAndPackages() async throws {
        let transport = FakeDSM()
        let profile = ServerProfile(name: "NAS", addresses: [ServerAddress(host: "nas.lan")], username: "nas-admin")
        let credentials = InMemoryCredentialProvider()
        await credentials.set(ServerCredentials(password: "pw"), for: profile.id)
        let backend = SynologyBackend(profile: profile, credentials: credentials, deviceName: "Tests", transport: transport)

        try await backend.connect(otp: nil)
        let updates = try await backend.updates()

        #expect(updates.map(\.name) == ["DSM", "Container Manager"])
        #expect(updates.first?.requiresReboot == true)
        #expect(updates.first?.installedVersion == "DSM 7.2.1-69057 Update 5")
    }

    @Test func notConnectedIsMapped() async {
        let profile = ServerProfile(name: "NAS", addresses: [ServerAddress(host: "nas.lan")], username: "nas-admin")
        let backend = SynologyBackend(profile: profile, credentials: InMemoryCredentialProvider(), deviceName: "Tests", transport: FakeDSM())
        await #expect(throws: BackendError.notConnected) { try await backend.systemSnapshot() }
    }
}
