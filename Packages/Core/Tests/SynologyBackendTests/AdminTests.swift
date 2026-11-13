import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("Control Panel and File Station")
struct AdminTests {
    @Test func detectsControlPanelAreas() async throws {
        let test = try await TestBackend.connected()
        let capabilities = await test.backend.capabilities()
        #expect(capabilities.isSuperset(of: [.settings, .updateSettings, .users, .terminal, .power, .connections, .files]))
    }

    @Test func readsUpdateSettings() async throws {
        let test = try await TestBackend.connected()
        let settings = try await test.backend.updateSettings()
        #expect(settings.policy == .importantOnly)
        #expect(settings.schedule?.contains("03:00") == true)
    }

    @Test func setsUpdatePolicyAsPOST() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.setUpdatePolicy(.notifyOnly)
        try await test.backend.setUpdatePolicy(.all)
        let calls = test.transport.calls("SYNO.Core.Upgrade.Setting", "set")
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.method == "POST" })
        #expect(calls[0].params["autoupdate_enable"] == "false")
        #expect(calls[1].params["autoupdate_type"] == #""all""#)
    }

    @Test func mapsUserStatusIncludingPastExpiry() async throws {
        let test = try await TestBackend.connected()
        let users = try await test.backend.users()
        #expect(users.map(\.name) == ["admin", "anna", "nas-admin"])
        #expect(users.first { $0.name == "admin" }?.isDisabled == true)
        #expect(users.first { $0.name == "anna" }?.isDisabled == true)
        #expect(users.first { $0.name == "anna" }?.email == "anna@example.lan")
        #expect(users.first { $0.name == "nas-admin" }?.isDisabled == false)
    }

    @Test func neverDisablesTheSignedInAccount() async throws {
        let test = try await TestBackend.connected()
        await #expect(throws: BackendError.self) {
            try await test.backend.setUser("NAS-Admin", disabled: true)
        }
        #expect(test.transport.calls("SYNO.Core.User", "set").isEmpty)

        try await test.backend.setUser("anna", disabled: true)
        let call = try #require(test.transport.calls("SYNO.Core.User", "set").first)
        #expect(call.params["name"] == #""anna""#)
        #expect(call.params["expired"] == #""now""#)
    }

    @Test func sshToggleKeepsThePort() async throws {
        let test = try await TestBackend.connected()
        #expect(try await test.backend.terminalSettings() == TerminalSettings(sshEnabled: true, sshPort: 2222))
        try await test.backend.setSSH(enabled: false)
        let call = try #require(test.transport.calls("SYNO.Core.Terminal", "set").first)
        #expect(call.params["enable_ssh"] == "false")
        #expect(call.params["ssh_port"] == "2222")
    }

    @Test func decodesActiveConnections() async throws {
        let test = try await TestBackend.connected()
        let connections = try await test.backend.activeConnections()
        #expect(connections.count == 2)
        #expect(connections.allSatisfy { $0.since != nil })
    }

    @Test func restartWaitsForTheNASAndSignsInAgain() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.perform(.restart) { _ in }
        #expect(test.transport.calls("SYNO.Core.System", "reboot").first?.method == "POST")
        #expect(test.transport.loginCount == 2)
    }

    @Test func shutDownEndsTheSessionWithoutLogout() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.perform(.shutDown) { _ in }
        #expect(test.transport.calls("SYNO.API.Auth", "logout").isEmpty)
        await #expect(throws: BackendError.notConnected) {
            _ = try await test.backend.installedPackages()
        }
    }

    // MARK: File Station

    @Test func listsSharesAndFoldersFirst() async throws {
        let test = try await TestBackend.connected()
        let shares = try await test.backend.sharedFolders()
        #expect(shares.map(\.name) == ["home", "photo"])

        let items = try await test.backend.folderContents("/photo")
        #expect(items.map(\.name) == ["2024", "2025", "cover.jpg"])
        #expect(items.last?.size == 3_100_000)
        #expect(items.first?.size == nil)
        let call = try #require(test.transport.calls("SYNO.FileStation.List", "list").first)
        #expect(call.params["folder_path"] == #""/photo""#)
    }

    @Test func moveStartsTaskWithoutOverwriteAndPolls() async throws {
        let test = try await TestBackend.connected()
        let progress = ProgressRecorder()
        try await test.backend.transfer("/photo/2024", to: "/home/Archive", mode: .move, progress: progress.handler)

        let start = try #require(test.transport.calls("SYNO.FileStation.CopyMove", "start").first)
        #expect(start.method == "POST")
        #expect(start.params["path"] == #"["/photo/2024"]"#)
        #expect(start.params["dest_folder_path"] == #""/home/Archive""#)
        #expect(start.params["overwrite"] == "false")
        #expect(start.params["remove_src"] == "true")
        #expect(test.transport.calls("SYNO.FileStation.CopyMove", "status").count == 3)
        #expect(progress.all.last == 1)
    }

    @Test func virtualMachineManagerListsAndControlsGuests() async throws {
        let test = try await TestBackend.connected()
        #expect(await test.backend.capabilities().contains(.vms))
        let guests = try await test.backend.guests()
        #expect(guests.map(\.name) == ["homeassistant", "win11"])
        #expect(guests[0].status == .running)
        #expect(guests[0].cores == 2)
        #expect(guests[0].maxMemoryBytes == Int64(4096) * 1024 * 1024, "got \(String(describing: guests[0].maxMemoryBytes))")
        #expect(guests[0].node == "DS923")
        #expect(guests[1].status == .stopped)

        try await test.backend.perform(.stop, guest: guests[1]) { _ in }
        let off = try #require(test.transport.calls("SYNO.Virtualization.API.Guest.Action", "poweroff").first)
        #expect(off.params["guest_id"] == "\"5a2d9b3e-1111-4c6f-9d2a-000000000002\"")
        #expect(off.method == "POST")

        try await test.backend.perform(.reboot, guest: guests[0]) { _ in }
        #expect(test.transport.calls("SYNO.Virtualization.API.Guest.Action", "shutdown").count == 1)
        #expect(test.transport.calls("SYNO.Virtualization.API.Guest.Action", "poweron").count == 1)
        #expect(test.transport.calls("SYNO.Virtualization.API.Guest", "list").count >= 3)
    }

    @Test func deleteStartsRecursiveTaskAndPolls() async throws {
        let test = try await TestBackend.connected()
        let progress = ProgressRecorder()
        try await test.backend.delete(["/photo/2024", "/photo/cover.jpg"], progress: progress.handler)

        let start = try #require(test.transport.calls("SYNO.FileStation.Delete", "start").first)
        #expect(start.method == "POST")
        #expect(start.params["path"] == #"["/photo/2024","/photo/cover.jpg"]"#)
        #expect(start.params["recursive"] == "true")
        #expect(test.transport.calls("SYNO.FileStation.Delete", "status").count == 3)
        #expect(progress.all.last == 1)
    }

    @Test func deleteWithoutPermissionHidesTheAction() async throws {
        let test = try await TestBackend.connected(configuration: {
            var config = FakeDSM.Configuration()
            config.errors["SYNO.FileStation.Delete/start"] = 105
            return config
        }())
        await #expect(throws: BackendError.actionNotPermitted) {
            try await test.backend.delete(["/photo/cover.jpg"]) { _ in }
        }
        #expect(await test.backend.deniedActions().contains(.deleteFiles))
    }

    @Test func copyDoesNotRemoveSource() async throws {
        let test = try await TestBackend.connected()
        try await test.backend.transfer("/photo/cover.jpg", to: "/home", mode: .copy) { _ in }
        #expect(test.transport.calls("SYNO.FileStation.CopyMove", "start").first?.params["remove_src"] == "false")
    }

    @Test func transferValidation() {
        let folder = FileItem(path: "/photo/2024", name: "2024", isDirectory: true)
        #expect(!FileValidation.canTransfer(folder, to: "/photo/2024", mode: .copy))
        #expect(!FileValidation.canTransfer(folder, to: "/photo/2024/Summer", mode: .move))
        #expect(!FileValidation.canTransfer(folder, to: "/photo", mode: .move))
        #expect(FileValidation.canTransfer(folder, to: "/photo", mode: .copy))
        #expect(FileValidation.canTransfer(folder, to: "/photo/2024-old", mode: .move))
        #expect(!FileValidation.canTransfer(folder, to: "/", mode: .copy))
        #expect(!FileValidation.isValidName("a/b"))
        #expect(!FileValidation.isValidName("  "))
        #expect(FileValidation.isValidName("Taxes 2025"))
    }
}
