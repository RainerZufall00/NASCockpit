import Foundation
import Testing
import Domain
import Networking
@testable import ProxmoxBackend

@Suite("Proxmox sign-in")
struct ProxmoxSignInTests {
    @Test func passwordLoginUsesTicketAndCSRF() async throws {
        let test = try await TestBackend.make()
        let login = try #require(test.transport.calls("POST", "access/ticket").first)
        #expect(login.params["username"] == "nas-admin@pve")
        #expect(login.params["password"] == "s3cret")
        #expect(login.headers["Cookie"] == nil)

        _ = try await test.backend.guests()
        let read = try #require(test.transport.calls("GET", "cluster/resources").first)
        #expect(read.headers["Cookie"]?.hasPrefix("PVEAuthCookie=PVE:nas-admin@pve:") == true)
        #expect(read.headers["CSRFPreventionToken"] == nil)

        let guest = VirtualGuest(id: "qemu/100", vmid: 100, name: "ha", node: "pve", kind: .virtualMachine, status: .stopped)
        try await test.backend.perform(.start, guest: guest) { _ in }
        let write = try #require(test.transport.calls("POST", "nodes/pve/qemu/100/status/start").first)
        #expect(write.headers["CSRFPreventionToken"] == "csrf-1")
        #expect(await test.backend.signedInUser() == "nas-admin@pve")
        #expect(await test.backend.capabilities().contains(.vms))
    }

    @Test func wrongPasswordIsInvalidCredentials() async throws {
        await #expect(throws: BackendError.invalidCredentials) {
            _ = try await TestBackend.make(secret: "wrong")
        }
    }

    @Test func tfaAsksForCodeThenSignsIn() async throws {
        var config = FakePVE.Configuration()
        config.requiresTFA = true
        let test = try await TestBackend.make(configuration: config, connect: false)
        await #expect(throws: BackendError.otpRequired) {
            try await test.backend.connect(otp: nil)
        }
        await #expect(throws: BackendError.otpInvalid) {
            try await test.backend.connect(otp: "000000")
        }
        try await test.backend.connect(otp: "123456")
        let second = test.transport.calls("POST", "access/ticket").last
        #expect(second?.params["password"] == "totp:123456")
        #expect(second?.params["tfa-challenge"]?.hasPrefix("PVE:!tfa!") == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.events.all.contains(.loggedIn(LoginInfo(usedOTP: true, hasDeviceToken: false, isReauthentication: false))))
    }

    @Test func apiTokenGoesInTheAuthorizationHeader() async throws {
        let test = try await TestBackend.make(authMethod: .apiToken, username: "nas-admin@pve!nascockpit", secret: "11111111-2222-3333-4444-555555555555")
        #expect(test.transport.calls("POST", "access/ticket").isEmpty)
        let verify = try #require(test.transport.calls("GET", "version").first)
        #expect(verify.headers["Authorization"] == "PVEAPIToken=nas-admin@pve!nascockpit=11111111-2222-3333-4444-555555555555")
        #expect(await test.backend.signedInUser() == "nas-admin@pve")
    }

    @Test func revokedTokenIsReportedAsInvalidCredentials() async throws {
        await #expect(throws: BackendError.invalidCredentials) {
            _ = try await TestBackend.make(authMethod: .apiToken, username: "nas-admin@pve!nascockpit", secret: "nope")
        }
    }

    @Test func expiredTicketTriggersExactlyOneRelogin() async throws {
        let test = try await TestBackend.make()
        test.transport.configure { $0.expireTicketsBefore = 1 }
        _ = try await test.backend.guests()
        #expect(test.transport.loginCount == 2)
        // Still broken afterwards: stop instead of looping.
        test.transport.configure { $0.expireTicketsBefore = 99 }
        await #expect(throws: BackendError.sessionLost) {
            _ = try await test.backend.guests()
        }
        #expect(test.transport.loginCount == 3)
    }

    @Test func openIDWithoutTokenNeedsTheBrowser() async throws {
        let test = try await TestBackend.make(authMethod: .openID(realm: "keycloak"), username: "", secret: nil, connect: false)
        await #expect(throws: BackendError.openIDSignInRequired) {
            try await test.backend.connect(otp: nil)
        }
    }

    @Test func openIDLoginExchangesTheCodeAndCanCreateAToken() async throws {
        let test = try await TestBackend.make(authMethod: .openID(realm: "keycloak"), username: "", secret: nil, authorizer: FakeAuthorizer())
        let authURL = try #require(test.transport.calls("POST", "access/openid/auth-url").first)
        #expect(authURL.params["realm"] == "keycloak")
        #expect(authURL.params["redirect-url"] == "nascockpit://oidc")
        let login = try #require(test.transport.calls("POST", "access/openid/login").first)
        #expect(login.params["code"] == "good-code")
        #expect(login.params["state"] == "state-1")
        #expect(await test.backend.signedInUser() == "oidc-user@keycloak")

        let token = try await test.backend.createAPIToken(name: "nascockpit-iphone")
        #expect(token.tokenID == "oidc-user@keycloak!nascockpit-iphone")
        #expect(token.secret == "new-secret")
        let create = try #require(test.transport.calls("POST", "access/users/oidc-user@keycloak/token/nascockpit-iphone").first)
        #expect(create.params["privsep"] == "0")
    }

    @Test func openIDWithWrongCodeFails() async throws {
        await #expect(throws: BackendError.invalidCredentials) {
            _ = try await TestBackend.make(authMethod: .openID(realm: "keycloak"), username: "", secret: nil, authorizer: FakeAuthorizer(code: "bad"))
        }
    }

    @Test func unreachableHostAndUntrustedCertificate() async throws {
        var config = FakePVE.Configuration()
        config.hostErrors["pve.lan"] = .unreachable
        await #expect(throws: BackendError.unreachable) {
            _ = try await TestBackend.make(configuration: config)
        }
        let info = CertificateInfo(spkiSHA256: "ab", certificateSHA256: "cd", subject: "CN=pve")
        config.hostErrors["pve.lan"] = .untrustedCertificate(info)
        await #expect(throws: BackendError.certificateUntrusted(info)) {
            _ = try await TestBackend.make(configuration: config)
        }
    }
}

@Suite("Proxmox data")
struct ProxmoxDataTests {
    @Test func guestsComeFromClusterResources() async throws {
        let test = try await TestBackend.make()
        let guests = try await test.backend.guests()
        #expect(guests.map(\.vmid) == [100, 101, 200, 900])
        let ha = try #require(guests.first)
        #expect(ha.kind == .virtualMachine)
        #expect(ha.status == .running)
        #expect(ha.tags == ["smarthome", "prod"])
        #expect(ha.cores == 2)
        #expect(ha.memoryUsage.map { abs($0 - 0.4639) < 0.001 } == true)
        let pihole = try #require(guests.first { $0.vmid == 200 })
        #expect(pihole.kind == .container)
        #expect(pihole.node == "pve2")
        #expect(pihole.lock == "backup")
        #expect(!pihole.canControl)
        #expect(GuestAction.available(for: pihole).isEmpty)
        let template = try #require(guests.last)
        #expect(template.isTemplate)
        #expect(GuestAction.available(for: ha) == [.shutdown, .reboot, .stop])
    }

    @Test func guestActionWaitsForTheTask() async throws {
        let test = try await TestBackend.make()
        let guest = VirtualGuest(id: "lxc/200", vmid: 200, name: "pihole", node: "pve", kind: .container, status: .running)
        try await test.backend.perform(.reboot, guest: guest) { _ in }
        #expect(test.transport.calls("POST", "nodes/pve/lxc/200/status/reboot").count == 1)
        #expect(test.transport.requests.filter { $0.path.hasSuffix("/status") && $0.path.contains("tasks/") }.count == 3)
    }

    @Test func guestAddressesPreferIPv4AndSkipLoopback() async throws {
        let test = try await TestBackend.make()
        let vm = VirtualGuest(id: "qemu/100", vmid: 100, name: "ha", node: "pve", kind: .virtualMachine, status: .running)
        #expect(try await test.backend.guestAddresses(vm) == ["192.168.1.100", "fd00::100"])
        let noAgent = VirtualGuest(id: "qemu/101", vmid: 101, name: "win", node: "pve", kind: .virtualMachine, status: .running)
        #expect(try await test.backend.guestAddresses(noAgent).isEmpty)
        let container = VirtualGuest(id: "lxc/200", vmid: 200, name: "pihole", node: "pve", kind: .container, status: .running)
        #expect(try await test.backend.guestAddresses(container) == ["192.168.1.200"])
    }

    @Test func sshLinksFollowTheTemplate() {
        #expect(SSHLink.url(host: "192.168.1.5", user: "root", port: 22, template: SSHLink.defaultTemplate)?.absoluteString == "ssh://root@192.168.1.5:22")
        #expect(SSHLink.url(host: "fd00::5", user: "me", port: 2222, template: SSHLink.defaultTemplate)?.absoluteString == "ssh://me@[fd00::5]:2222")
        #expect(SSHLink.url(host: "pve.lan", user: "a b", port: 22, template: "webssh://{user}@{host}:{port}")?.absoluteString == "webssh://a%20b@pve.lan:22")
    }

    @Test func failedTaskReportsExitStatus() async throws {
        var config = FakePVE.Configuration()
        config.taskExitStatus = "VM is locked (backup)"
        let test = try await TestBackend.make(configuration: config)
        let guest = VirtualGuest(id: "qemu/100", vmid: 100, name: "ha", node: "pve", kind: .virtualMachine, status: .running)
        await #expect(throws: BackendError.operationFailed("VM is locked (backup)")) {
            try await test.backend.perform(.stop, guest: guest) { _ in }
        }
    }

    @Test func forbiddenActionIsRememberedAsDenied() async throws {
        var config = FakePVE.Configuration()
        config.errors["POST nodes/pve/qemu/100/status/stop"] = (403, "Permission check failed (/vms/100, VM.PowerMgmt)")
        let test = try await TestBackend.make(configuration: config)
        let guest = VirtualGuest(id: "qemu/100", vmid: 100, name: "ha", node: "pve", kind: .virtualMachine, status: .running)
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.perform(.stop, guest: guest) { _ in }
        }
        #expect(await test.backend.deniedActions().contains(.guestControl))
        #expect(await test.backend.deniedActions().contains(.packageUpdate))
    }

    @Test func snapshotMapsNodeStorageAndDisks() async throws {
        let test = try await TestBackend.make()
        let snapshot = try await test.backend.systemSnapshot()
        #expect(snapshot.osVersion == "Proxmox VE 8.3.2")
        #expect(snapshot.model.hasPrefix("pve · 12th Gen Intel Core i5-1235U"))
        #expect(snapshot.cpuLoad.map { abs($0 - 0.1834) < 0.0001 } == true)
        #expect(snapshot.memoryUsage.map { abs($0 - 0.71) < 0.001 } == true)
        #expect(snapshot.memoryTotalBytes == 67_108_864_000)
        #expect(snapshot.uptime == 2_345_678)
        #expect(snapshot.network?.rxBytesPerSecond == 1_200_000.5)
        #expect(snapshot.volumes.map(\.id) == ["rootfs", "local", "local-zfs", "nas-backup"])
        #expect(snapshot.volumes.last?.status == .warning)
        #expect(snapshot.disks.map(\.status) == [.normal, .crashed])
        #expect(snapshot.disks.first?.name == "nvme0n1 (NVME)")
        #expect(snapshot.hasStorageProblem)
    }

    @Test func hostUpdatesAreListedButNotInstallable() async throws {
        let test = try await TestBackend.make()
        let updates = try await test.backend.updates()
        #expect(updates.map(\.name) == ["openssl", "proxmox-kernel-6.8.12-8-pve-signed", "pve-manager"])
        #expect(updates.allSatisfy { !$0.isSystemUpdate })
        let kernel = try #require(updates.first { $0.name.contains("kernel") })
        #expect(kernel.requiresReboot)
        #expect(kernel.installedVersion == "")
        #expect(updates.last?.installedVersion == "8.3.2")
        #expect(updates.last?.availableVersion == "8.3.3")
        await #expect(throws: BackendError.notSupported) {
            try await test.backend.installPackageUpdate("pve-manager") { _ in }
        }
        try await test.backend.refreshUpdateCatalog()
        #expect(test.transport.calls("POST", "nodes/pve/apt/update").count == 1)
    }

    @Test func backupJobsGetTheirLastRunFromTheTaskHistory() async throws {
        let test = try await TestBackend.make()
        let tasks = try await test.backend.backupTasks()
        #expect(tasks.count == 2)
        let daily = try #require(tasks.first)
        #expect(daily.name == "Daily to NAS")
        #expect(daily.destination == .other("nas-backup"))
        // Newest finished vzdump task for guest 101 failed.
        #expect(daily.lastResult == .failed)
        #expect(daily.activity == .running(progress: nil))
        #expect(daily.nextBackup == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(daily.lastBackup == Date(timeIntervalSince1970: 1_729_900_000))
        let weekly = try #require(tasks.last)
        #expect(weekly.activity == .suspended)
        #expect(weekly.nextBackup == nil)
        // Bound to pve2, which has no tasks: nothing known about its last run.
        #expect(weekly.lastResult == nil)
    }

    @Test func backUpNowReplaysTheJobOnItsNode() async throws {
        let test = try await TestBackend.make()
        try await test.backend.perform(.start, backup: "backup-5f3a1c2d-1e2f")
        let run = try #require(test.transport.calls("POST", "nodes/pve/vzdump").first)
        #expect(run.params["vmid"] == "100,101")
        #expect(run.params["storage"] == "nas-backup")
        #expect(run.params["mode"] == "snapshot")
        #expect(run.params["compress"] == "zstd")
        #expect(run.params["prune-backups"] == "keep-daily=7,keep-weekly=4")
        // Proxmox returns these as objects; vzdump wants property strings again.
        #expect(run.params["performance"] == "max-workers=16")
        #expect(run.params["fleecing"] == "enabled=0")
        #expect(run.params["job-id"] == "backup-5f3a1c2d-1e2f")
        #expect(run.params["schedule"] == nil)
        #expect(run.params["id"] == nil)

        try await test.backend.perform(.cancel, backup: "backup-5f3a1c2d-1e2f")
        #expect(test.transport.requests.contains { $0.method == "DELETE" && $0.path.hasPrefix("nodes/pve/tasks/UPID:pve:000A1B2C") })
    }

    @Test func syslogLinesBecomeLogEntries() async throws {
        let test = try await TestBackend.make()
        let page = try await test.backend.logs(LogQuery(source: .system, limit: 50))
        #expect(page.entries.count == 3)
        #expect(page.total == 3)
        #expect(page.nextOffset == nil)
        let auth = try #require(page.entries.first)
        #expect(auth.category == "pvedaemon")
        #expect(auth.message == "<root@pam> successful auth for user 'root@pam'")
        #expect(auth.level == .info)
        #expect(auth.date.map { Calendar.current.component(.month, from: $0) } == 11)
        #expect(page.entries[1].level == .error)
        #expect(page.entries[2].category == "systemd")

        let connections = try await test.backend.logs(LogQuery(source: .connection, limit: 50))
        #expect(test.transport.calls("GET", "nodes/pve/syslog").last?.params["service"] == "pvedaemon")
        #expect(connections.entries.count == 2)

        let backups = try await test.backend.logs(LogQuery(source: .backup, limit: 50))
        #expect(backups.entries.map(\.level) == [.info, .error, .info])
        #expect(backups.entries[1].message.contains("job errors"))
    }

    @Test func rebootWaitsForTheHostAndSignsInAgain() async throws {
        let test = try await TestBackend.make()
        try await test.backend.perform(.restart) { _ in }
        #expect(test.transport.calls("POST", "nodes/pve/status").first?.params["command"] == "reboot")
        #expect(test.transport.loginCount == 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.events.all.contains(.state(.rebooting)))
        #expect(test.events.all.last == .state(.connected))
    }

    @Test func unsupportedFeaturesSayNotSupported() async throws {
        let test = try await TestBackend.make()
        await #expect(throws: BackendError.notSupported) { _ = try await test.backend.sharedFolders() }
        await #expect(throws: BackendError.notSupported) { _ = try await test.backend.containers() }
        await #expect(throws: BackendError.notSupported) { _ = try await test.backend.notifications() }
    }
}

@Suite("Proxmox request builder")
struct PVERequestTests {
    @Test func httpIsRefused() {
        let address = ServerAddress(host: "pve.lan", port: 8006, usesHTTPS: false)
        #expect(throws: PVEError.invalidAddress) {
            _ = try PVERequestBuilder.request(address: address, method: .get, path: "version", params: [:], auth: nil, timeout: 5)
        }
    }

    @Test func parametersAreEncodedAndParsedBack() throws {
        let address = ServerAddress(host: "pve.lan", port: 8006)
        let request = try PVERequestBuilder.request(address: address, method: .post, path: "access/ticket", params: ["username": "a b@pam", "password": "p&w=1+2"], auth: nil, timeout: 5)
        #expect(request.url?.absoluteString == "https://pve.lan:8006/api2/json/access/ticket")
        #expect(PVERequestBuilder.parameters(of: request) == ["username": "a b@pam", "password": "p&w=1+2"])
        let read = try PVERequestBuilder.request(address: address, method: .get, path: "nodes", params: ["type": "vm"], auth: .token("u@pam!t=s"), timeout: 5)
        #expect(read.url?.query() == "type=vm")
        #expect(read.value(forHTTPHeaderField: "Authorization") == "PVEAPIToken=u@pam!t=s")
    }

    @Test func authMethodRoundTrips() {
        for method in [AuthMethod.password, .apiToken, .openID(realm: "key:cloak")] {
            #expect(AuthMethod(rawValue: method.rawValue) == method)
        }
        let profile = ServerProfile(name: "x", addresses: [], backend: .proxmox, authMethod: .openID(realm: "r"), username: "me@r")
        #expect(!profile.canSignInUnattended)
        var withToken = profile
        withToken.username = "me@r!nascockpit"
        #expect(withToken.hasAPIToken)
        #expect(withToken.canSignInUnattended)
    }
}

@Suite("Proxmox snapshots")
struct ProxmoxSnapshotTests {
    let vm = VirtualGuest(id: "qemu/100", vmid: 100, name: "ha", node: "pve", kind: .virtualMachine, status: .running)
    let container = VirtualGuest(id: "lxc/200", vmid: 200, name: "pihole", node: "pve", kind: .container, status: .running)

    @Test func listsSnapshotsNewestFirstWithoutCurrent() async throws {
        let test = try await TestBackend.make()
        #expect(await test.backend.capabilities().contains(.guestSnapshots))
        let snapshots = try await test.backend.snapshots(of: vm)
        #expect(snapshots.map(\.name) == ["before_update", "clean"])
        #expect(snapshots[0].includesMemory)
        #expect(snapshots[0].description == "HA 2026.10")
        #expect(snapshots[0].parent == "clean")
        #expect(snapshots[0].date == Date(timeIntervalSince1970: 1_730_000_000))
        #expect(!snapshots[1].includesMemory)
    }

    @Test func createSendsNameDescriptionAndRAMOnlyForVMs() async throws {
        let test = try await TestBackend.make()
        try await test.backend.createSnapshot(of: vm, name: "before_update", description: "HA", includeMemory: true) { _ in }
        let vmCall = try #require(test.transport.calls("POST", "nodes/pve/qemu/100/snapshot").first)
        #expect(vmCall.params["snapname"] == "before_update")
        #expect(vmCall.params["description"] == "HA")
        #expect(vmCall.params["vmstate"] == "1")
        #expect(vmCall.headers["CSRFPreventionToken"] != nil)

        try await test.backend.createSnapshot(of: container, name: "pre", description: "", includeMemory: true) { _ in }
        let ctCall = try #require(test.transport.calls("POST", "nodes/pve/lxc/200/snapshot").first)
        #expect(ctCall.params["vmstate"] == nil)
        #expect(ctCall.params["description"] == nil)
    }

    @Test func invalidNameIsRejectedBeforeAnyRequest() async throws {
        let test = try await TestBackend.make()
        await #expect(throws: BackendError.self) {
            try await test.backend.createSnapshot(of: vm, name: "1 bad name", description: "", includeMemory: false) { _ in }
        }
        #expect(test.transport.calls("POST", "nodes/pve/qemu/100/snapshot").isEmpty)
    }

    @Test func rollbackAndDeleteWaitForTheTask() async throws {
        let test = try await TestBackend.make()
        let before = test.transport.requests.filter { $0.path.contains("/tasks/UPID") }.count
        try await test.backend.rollback(vm, to: "before_update") { _ in }
        #expect(test.transport.calls("POST", "nodes/pve/qemu/100/snapshot/before_update/rollback").count == 1)
        try await test.backend.deleteSnapshot("pre", of: container) { _ in }
        #expect(test.transport.calls("DELETE", "nodes/pve/lxc/200/snapshot/pre").count == 1)
        #expect(test.transport.requests.filter { $0.path.contains("/tasks/UPID") }.count > before)
    }

    @Test func failedTaskReportsProxmoxMessage() async throws {
        let test = try await TestBackend.make()
        test.transport.configure { $0.taskExitStatus = "snapshot feature is not available" }
        await #expect(throws: BackendError.operationFailed("snapshot feature is not available")) {
            try await test.backend.createSnapshot(of: container, name: "pre", description: "", includeMemory: false) { _ in }
        }
    }

    @Test func permissionDeniedHidesSnapshotActions() async throws {
        let test = try await TestBackend.make()
        test.transport.configure { $0.errors = ["POST nodes/pve/qemu/100/snapshot": (403, "Permission check failed (/vms/100, VM.Snapshot)")] }
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.createSnapshot(of: vm, name: "pre", description: "", includeMemory: false) { _ in }
        }
        #expect(await test.backend.deniedActions().contains(.guestSnapshot))
    }
}
