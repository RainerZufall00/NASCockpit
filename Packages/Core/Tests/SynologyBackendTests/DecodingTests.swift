import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("DSM decoding")
struct DecodingTests {
    let serverID = UUID()

    @Test func catalog() throws {
        let entries = try DSMDecoding.decode(Fixture.data("api_info"), api: "SYNO.API.Info", as: [String: APICatalog.Entry].self)
        let catalog = APICatalog(entries: entries)
        let auth = try catalog.resolve(api: "SYNO.API.Auth", versions: 6...7)
        #expect(auth.path == "entry.cgi")
        #expect(auth.version == 7)
        #expect(try catalog.resolve(api: "SYNO.Core.System", versions: 1...1).version == 1)
        #expect(throws: DSMError.unsupported("SYNO.Virtualization.Guest")) {
            try catalog.resolve(api: "SYNO.Virtualization.Guest", versions: 1...1)
        }
        #expect(throws: DSMError.unsupported("SYNO.API.Auth")) {
            try catalog.resolve(api: "SYNO.API.Auth", versions: 8...9)
        }
    }

    @Test func errorEnvelopeWinsOverDataShape() {
        #expect(throws: DSMError.sessionExpired) {
            try DSMDecoding.decode(Fixture.error(106), api: "SYNO.Core.System", as: SystemInfoDTO.self)
        }
        #expect(throws: DSMError.sessionExpired) {
            try DSMDecoding.decode(Fixture.error(119), api: "SYNO.Core.System", as: SystemInfoDTO.self)
        }
        #expect(throws: DSMError.sessionInterrupted) {
            try DSMDecoding.decode(Fixture.error(107), api: "SYNO.Core.System", as: SystemInfoDTO.self)
        }
        #expect(throws: DSMError.permissionDenied) {
            try DSMDecoding.decode(Fixture.error(105), api: "SYNO.Core.System", as: SystemInfoDTO.self)
        }
    }

    @Test(arguments: [
        (400, BackendError.invalidCredentials), (401, .accountDisabled), (402, .permissionDenied),
        (403, .otpRequired), (404, .otpInvalid), (406, .twoFactorSetupRequired), (407, .ipBlocked), (410, .passwordExpired),
    ])
    func loginErrorCodes(code: Int, expected: BackendError) {
        #expect(DSMError.backendError(from: DSMError.from(code: code, api: "SYNO.API.Auth")) == expected)
    }

    @Test func loginCodesOnlyApplyToAuth() {
        #expect(DSMError.from(code: 400, api: "SYNO.Core.Package") == .api(code: 400))
    }

    @Test func snapshotFromCompound() throws {
        let compound = try DSMDecoding.decode(Fixture.data("compound"), api: "SYNO.Entry.Request", as: CompoundResponse.self)
        #expect(compound.result.count == 3)
        let info = compound.result[0].decode(SystemInfoDTO.self)
        let utilization = compound.result[1].decode(UtilizationDTO.self)
        let storage = compound.result[2].decode(StorageDTO.self)
        let snapshot = DSMMapping.snapshot(info: info, utilization: utilization, storage: storage)

        #expect(snapshot.model == "DS920+")
        #expect(snapshot.osVersion == "DSM 7.2.1-69057 Update 5")
        let expectedUptime: TimeInterval = 342 * 3600 + 15 * 60 + 7
        #expect(snapshot.uptime == expectedUptime)
        #expect(snapshot.temperature == 44)
        #expect(snapshot.cpuLoad == 0.2)
        #expect(snapshot.memoryUsage == 0.41)
        let expectedMemory: Int64 = 8_388_608 * 1024
        #expect(snapshot.memoryTotalBytes == expectedMemory)
        #expect(snapshot.network == NetworkThroughput(rxBytesPerSecond: 2_500_000, txBytesPerSecond: 640_000))
        #expect(snapshot.diskReadBytesPerSecond == 1_048_576)
    }

    @Test func storageIsTolerant() throws {
        let storage = try DSMDecoding.decode(Fixture.data("storage"), api: "SYNO.Storage.CGI.Storage", as: StorageDTO.self)
        let snapshot = DSMMapping.snapshot(info: nil, utilization: nil, storage: storage)

        // The malformed third volume is skipped instead of failing the whole response.
        #expect(snapshot.volumes.count == 2)
        let first = snapshot.volumes[0]
        #expect(first.name == "Volume 1")
        #expect(first.totalBytes == 11_518_464_000_000)
        #expect(first.status == .normal)
        #expect(snapshot.volumes[1].status == .degraded)
        #expect(snapshot.volumes[1].usage == 0.95)
        #expect(snapshot.disks[0].model == "HAT5300-4T")
        // A S.M.A.R.T. warning wins over a "normal" disk status.
        #expect(snapshot.disks[1].status == .warning)
        #expect(snapshot.disks[1].temperature == 36)
        #expect(snapshot.hasStorageProblem)
    }

    @Test func packagesWithAvailableUpdates() throws {
        let installed = try DSMDecoding.decode(Fixture.data("packages"), api: "SYNO.Core.Package", as: PackageListDTO.self)
        let server = try DSMDecoding.decode(Fixture.data("server_packages"), api: "SYNO.Core.Package.Server", as: ServerPackageListDTO.self)
        let packages = DSMMapping.packages(installed, serverCatalog: server)

        #expect(packages.map(\.name) == ["Container Manager", "Hyper Backup", "Text Editor"])
        #expect(packages[0].availableVersion == "24.0.2-1541")
        #expect(packages[0].status == .running)
        // An older version on the server is not an update.
        #expect(packages[1].availableVersion == nil)
        #expect(packages[1].status == .stopped)
        #expect(packages[2].status == .unknown)
    }

    @Test func systemUpdate() throws {
        let check = try DSMDecoding.decode(Fixture.data("upgrade_check"), api: "SYNO.Core.Upgrade.Server", as: UpgradeCheckDTO.self)
        let item = try #require(DSMMapping.systemUpdate(check, installedVersion: "DSM 7.2.1", serverID: serverID))
        #expect(item.availableVersion == "DSM 7.2.2-72806 Update 3")
        #expect(item.requiresReboot)
        #expect(item.isSystemUpdate)
    }

    @Test func noSystemUpdate() throws {
        let data = Data(#"{"success":true,"data":{"update":{"available":false}}}"#.utf8)
        let check = try DSMDecoding.decode(data, api: "SYNO.Core.Upgrade.Server", as: UpgradeCheckDTO.self)
        #expect(DSMMapping.systemUpdate(check, installedVersion: nil, serverID: serverID) == nil)
    }

    @Test func logs() throws {
        let dto = try DSMDecoding.decode(Fixture.data("logs"), api: "SYNO.Core.SyslogClient.Log", as: LogListDTO.self)
        let page = DSMMapping.logPage(dto, query: LogQuery(offset: 100, limit: 4))

        #expect(page.total == 250)
        #expect(page.nextOffset == 104)
        #expect(page.entries.map(\.level) == [.info, .warning, .error, .info])
        #expect(page.entries.first?.id == 100)
        #expect(page.entries.first?.user == "admin")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try #require(page.entries.first?.date))
        #expect(components.year == 2026 && components.month == 11 && components.hour == 7 && components.minute == 12)
    }

    @Test func logLevelsAreFilteredClientSide() throws {
        let dto = try DSMDecoding.decode(Fixture.data("logs"), api: "SYNO.Core.SyslogClient.Log", as: LogListDTO.self)
        let page = DSMMapping.logPage(dto, query: LogQuery(offset: 0, limit: 4, levels: [.error]))
        #expect(page.entries.map(\.level) == [.error])
        // Pagination still advances by the raw page size.
        #expect(page.nextOffset == 4)
    }

    @Test func loginResponseAcceptsBothDeviceIDKeys() throws {
        let did = try DSMDecoding.decode(Data(#"{"success":true,"data":{"sid":"a","synotoken":"t","did":"d1"}}"#.utf8), api: "SYNO.API.Auth", as: LoginResponse.self)
        let deviceID = try DSMDecoding.decode(Data(#"{"success":true,"data":{"sid":"a","device_id":"d2"}}"#.utf8), api: "SYNO.API.Auth", as: LoginResponse.self)
        let none = try DSMDecoding.decode(Data(#"{"success":true,"data":{"sid":"a","did":""}}"#.utf8), api: "SYNO.API.Auth", as: LoginResponse.self)
        #expect(did.deviceID == "d1")
        #expect(did.synoToken == "t")
        #expect(deviceID.deviceID == "d2")
        #expect(none.deviceID == nil)
    }

    @Test(arguments: [
        ("24.0.2-1541", "24.0.2-1535", true),
        ("24.0.2-1535", "24.0.2-1535", false),
        ("4.1.0-3700", "4.1.1-3733", false),
        ("DSM 7.2.2-72806", "DSM 7.2.1-69057 Update 5", true),
        ("DSM 7.2.2-72806 Update 3", "DSM 7.2.2-72806", true),
    ])
    func versionComparison(candidate: String, installed: String, newer: Bool) {
        #expect(VersionComparator.isNewer(candidate, than: installed) == newer)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = DSMRequestBuilder.formEncode(["passwd": "a+b&c=d ü", "account": "me"])
        #expect(encoded == "account=me&passwd=a%2Bb%26c%3Dd%20%C3%BC")
    }

    @Test func healthMapping() {
        #expect(DSMMapping.health("normal") == .normal)
        #expect(DSMMapping.health("degrade") == .degraded)
        #expect(DSMMapping.health("crashed") == .crashed)
        #expect(DSMMapping.health("attention") == .warning)
        #expect(DSMMapping.health(nil) == .unknown)
    }
}
