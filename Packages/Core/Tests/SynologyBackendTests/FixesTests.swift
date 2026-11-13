import Foundation
import Testing
import Domain
@testable import SynologyBackend

@Suite("Logs and HTTP")
struct FixesTests {
    @Test func logQuerySendsLogTypeAsPlainStrings() async throws {
        let test = try await TestBackend.connected()
        _ = try await test.backend.logs(LogQuery(keyword: "volume", levels: [.error]))
        _ = try await test.backend.logs(LogQuery(source: .connection))
        let calls = test.transport.calls("SYNO.Core.SyslogClient.Log", "list")
        #expect(calls.count == 2)
        #expect(calls[0].params["logtype"] == "system")
        #expect(calls[0].params["target"] == "LOCAL")
        #expect(calls[0].params["dir"] == "desc")
        #expect(calls[0].params["keyword"] == "volume")
        // Level and date are filtered on the device.
        #expect(calls[0].params["level"] == nil)
        #expect(calls[1].params["logtype"] == "connection")
    }

    @Test func rejectedLogParametersFallBackStepByStep() async throws {
        var config = FakeDSM.Configuration()
        config.rejectsFilteredLogs = 5017
        let test = try await TestBackend.connected(configuration: config)

        let page = try await test.backend.logs(LogQuery(levels: [.error]))
        #expect(page.entries.map(\.level) == [.error])

        _ = try await test.backend.logs(LogQuery())
        let calls = test.transport.calls("SYNO.Core.SyslogClient.Log", "list")
        // plain and JSON variants rejected, then logtype only, which is kept for the next query.
        #expect(calls.count == 4)
        #expect(calls[1].params["target"] == #""LOCAL""#)
        #expect(calls[2].params == calls[3].params)
        #expect(calls[3].params["logtype"] == "system")
        #expect(calls[3].params["target"] == nil)
    }

    @Test func minimalQueryIsTheLastResortAndSearchesOnDevice() async throws {
        var config = FakeDSM.Configuration()
        config.rejectsFilteredLogs = 5017
        config.rejectedLogParameters = ["logtype"]
        let test = try await TestBackend.connected(configuration: config)
        let page = try await test.backend.logs(LogQuery(keyword: "drive"))
        #expect(page.entries.map(\.message) == ["Drive 2 reported a S.M.A.R.T. error."])
        let last = try #require(test.transport.calls("SYNO.Core.SyslogClient.Log", "list").last)
        #expect(last.params["logtype"] == nil && last.params["target"] == nil && last.params["keyword"] == nil)
        #expect(last.params["start"] == "0")
    }

    @Test func pagingStopsBeforeTheTimeRange() throws {
        let dto = try DSMDecoding.decode(Fixture.data("logs"), api: "SYNO.Core.SyslogClient.Log", as: LogListDTO.self)
        let from = try #require(DSMMapping.parseLogDate("2026/11/06 00:00:00"))
        let page = DSMMapping.logPage(dto, query: LogQuery(offset: 0, limit: 4, from: from))
        #expect(page.entries.count == 2)
        #expect(page.nextOffset == nil)
    }

    @Test func eventAndUserFieldsAreAccepted() throws {
        let json = #"{"success":true,"data":{"total":1,"items":[{"event":"Certificate renewed.","user":"SYSTEM","level":"info","time":"2026/11/08 01:00:00"}]}}"#
        let dto = try DSMDecoding.decode(Data(json.utf8), api: "SYNO.Core.SyslogClient.Log", as: LogListDTO.self)
        let page = DSMMapping.logPage(dto, query: LogQuery(source: .system))
        #expect(page.entries.first?.message == "Certificate renewed.")
        #expect(page.entries.first?.user == "SYSTEM")
        #expect(page.entries.first?.category == "System")
    }

    @Test func hyperBackupLogSplitsTaskNames() async throws {
        let test = try await TestBackend.connected()
        #expect(await test.backend.capabilities().contains(.backupLogs))
        let page = try await test.backend.logs(LogQuery(source: .backup, keyword: "task"))
        #expect(page.entries.map(\.category) == ["Offsite", "Offsite", "USB Photos", "Docker to Office", "Hyper Backup"])
        #expect(page.entries[0].message.hasPrefix("Backup task finished successfully."))
        #expect(page.entries.map(\.level) == [.info, .info, .warning, .error, .info])
        #expect(page.nextOffset == nil)

        let call = try #require(test.transport.calls("SYNO.SDS.Backup.Client.Common.Log", "list").first)
        #expect(call.params["filter_keyword"] == "task")
        #expect(call.params["filter_date_from"] == "0")
        #expect(test.transport.calls("SYNO.Core.SyslogClient.Log", "list").isEmpty)

        let offsite = try await test.backend.logs(LogQuery(source: .backup, backupTask: "offsite"))
        #expect(offsite.entries.count == 2)
    }

    @Test func serverErrorCodeHasNoGroupingSeparator() {
        #expect(BackendError.server(code: 5017).localizedDescription.contains("5017"))
    }

    @Test func plainHTTPOnlyForPrivateHosts() {
        for host in ["192.168.1.10", "10.0.0.2", "172.20.1.1", "100.101.102.103", "nas.local", "nas", "my-nas.tail1234.ts.net", "fd12:3456::1", "[fe80::1]", "169.254.3.4"] {
            #expect(ServerAddress.isPrivateNetworkHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "nas.example.com", "myname.synology.me", "2001:db8::1", "192.168.1", "", "256.1.1.1"] {
            #expect(!ServerAddress.isPrivateNetworkHost(host), "\(host)")
        }
    }

    @Test func requestBuilderUsesSchemeAndRefusesPublicHTTP() throws {
        let local = ServerAddress(host: "192.168.1.10", port: 5000, usesHTTPS: false)
        let request = try DSMRequestBuilder.request(address: local, path: "entry.cgi", params: [:], isWrite: false, timeout: 5, session: nil)
        #expect(request.url?.absoluteString.hasPrefix("http://192.168.1.10:5000/webapi/entry.cgi") == true)

        let remote = ServerAddress(host: "nas.example.com", port: 5000, usesHTTPS: false)
        #expect(throws: DSMError.invalidAddress) {
            _ = try DSMRequestBuilder.request(address: remote, path: "entry.cgi", params: [:], isWrite: false, timeout: 5, session: nil)
        }
    }

    @Test func addressesSavedBeforeHTTPExistedStayHTTPS() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","host":"nas.lan","port":5001,"label":"LAN"}"#
        let address = try JSONDecoder().decode(ServerAddress.self, from: Data(old.utf8))
        #expect(address.usesHTTPS)
        #expect(address.port == 5001)

        let roundTrip = try JSONDecoder().decode(ServerAddress.self, from: JSONEncoder().encode(ServerAddress(host: "nas", port: 5000, usesHTTPS: false)))
        #expect(!roundTrip.usesHTTPS)
    }
}
