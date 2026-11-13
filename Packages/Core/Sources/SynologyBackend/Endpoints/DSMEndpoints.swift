import Foundation
import Domain

/// All DSM endpoints in one place, grouped by feature. When a DSM update changes an
/// API, this is the single place to adapt (plus the fixture tests).
enum DSMEndpoints {
    enum Info {
        static let api = "SYNO.API.Info"
        static let path = "query.cgi"
    }

    enum Auth {
        static let api = "SYNO.API.Auth"

        /// POST, so the password never appears in a URL.
        static func login(_ params: [String: String]) -> DSMEndpoint<LoginResponse> {
            DSMEndpoint(api: api, method: "login", versions: 6...7, params: params, isWrite: true, documentation: .official, timeout: 15)
        }

        static var logout: DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "logout", versions: 6...7, isWrite: true, documentation: .official, timeout: 5)
        }
    }

    enum Entry {
        /// Bundles several read calls into one request (dashboard, background refresh).
        static func request(compound: String) -> DSMEndpoint<CompoundResponse> {
            DSMEndpoint(
                api: "SYNO.Entry.Request",
                method: "request",
                versions: 1...1,
                params: ["compound": compound, "stop_when_error": "false"],
                isWrite: true // POST because the payload can be long; it only contains reads.
            )
        }
    }

    enum System {
        static var info: DSMEndpoint<SystemInfoDTO> {
            DSMEndpoint(api: "SYNO.Core.System", method: "info", versions: 1...1)
        }

        /// UNVERIFIED: `info` with `type=network` lists the network interfaces (`nif`) with MAC and netmask.
        static var network: DSMEndpoint<NetworkInfoDTO> {
            DSMEndpoint(api: "SYNO.Core.System", method: "info", versions: 1...1, params: ["type": "network"])
        }

        static var utilization: DSMEndpoint<UtilizationDTO> {
            DSMEndpoint(api: "SYNO.Core.System.Utilization", method: "get", versions: 1...1)
        }
    }

    enum Storage {
        static var loadInfo: DSMEndpoint<StorageDTO> {
            DSMEndpoint(api: "SYNO.Storage.CGI.Storage", method: "load_info", versions: 1...1)
        }
    }

    enum Packages {
        static var installed: DSMEndpoint<PackageListDTO> {
            DSMEndpoint(
                api: "SYNO.Core.Package",
                method: "list",
                versions: 1...2,
                params: ["additional": #"["status","description"]"#]
            )
        }

        /// UNVERIFIED: how DSM 7.2 exposes available package updates. Compared by version.
        static var serverCatalog: DSMEndpoint<ServerPackageListDTO> { serverCatalog(forceReload: false) }

        /// `blforcereload=true` makes DSM ask the package server again instead of answering from its cache.
        static func serverCatalog(forceReload: Bool) -> DSMEndpoint<ServerPackageListDTO> {
            DSMEndpoint(
                api: "SYNO.Core.Package.Server",
                method: "list",
                versions: 1...2,
                params: ["blforcereload": forceReload ? "true" : "false", "blloadothers": "false"],
                timeout: forceReload ? 60 : 30
            )
        }
    }

    enum Upgrade {
        /// UNVERIFIED: `SYNO.Core.Upgrade.*` must be checked against a real DSM.
        static var check: DSMEndpoint<UpgradeCheckDTO> {
            DSMEndpoint(api: "SYNO.Core.Upgrade.Server", method: "check", versions: 1...4, timeout: 30)
        }
    }

    enum Logs {
        static let api = "SYNO.Core.SyslogClient.Log"

        /// How the request is phrased. DSM's parameters are undocumented: open-source clients send
        /// `logtype=system|connection`, `target=LOCAL`, `dir=desc` as plain strings; without `logtype`
        /// DSM returned only one category (seen: certificate entries). The backend starts with the first
        /// variant and moves on when the NAS answers with an API error (seen: 5017).
        /// Level and date are always filtered on the device.
        enum Variant: Int, CaseIterable, Sendable {
            /// logtype, target, dir, keyword as plain strings.
            case plain
            /// The same values JSON-encoded (`"LOCAL"`), as some DSM APIs expect.
            case json
            /// Only `logtype`.
            case typeOnly
            /// Only paging. Last resort; DSM picks the category.
            case minimal
        }

        static func list(_ query: LogQuery, variant: Variant) -> DSMEndpoint<LogListDTO> {
            var params: [String: String] = [
                "start": String(query.offset),
                "limit": String(query.limit),
            ]
            let logType = query.source == .connection ? "connection" : "system"
            func value(_ string: String) -> String { variant == .json ? jsonString(string) : string }
            switch variant {
            case .plain, .json:
                params["logtype"] = value(logType)
                params["target"] = value("LOCAL")
                params["dir"] = value("desc")
                if let keyword = query.keyword, !keyword.isEmpty {
                    params["keyword"] = value(keyword)
                }
            case .typeOnly:
                params["logtype"] = logType
            case .minimal:
                break
            }
            return DSMEndpoint(api: api, method: "list", versions: 1...1, params: params)
        }
    }

    enum BackupLog {
        static let api = "SYNO.SDS.Backup.Client.Common.Log"

        /// UNVERIFIED (open-source clients): plain `filter_keyword`, epoch `filter_date_from/to` (0 = open).
        /// DSM ignores task and level filters here; both are applied on the device.
        static func list(_ query: LogQuery) -> DSMEndpoint<BackupLogListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...1, params: [
                "offset": String(query.offset),
                "limit": String(query.limit),
                "filter_keyword": query.keyword ?? "",
                "filter_date_from": String(Int(query.from?.timeIntervalSince1970 ?? 0)),
                "filter_date_to": String(Int(query.to?.timeIntervalSince1970 ?? 0)),
            ], timeout: 20)
        }
    }

    /// Feature detection by API presence in the catalog.
    static let capabilityAPIs: [(Capability, String)] = [
        (.dashboard, "SYNO.Core.System"),
        (.packages, "SYNO.Core.Package"),
        (.systemUpdate, "SYNO.Core.Upgrade.Server"),
        (.containers, "SYNO.Docker.Container"),
        (.logs, Logs.api),
        (.files, "SYNO.FileStation.List"),
        (.vms, Virtualization.guestAPI),
        (.updateSettings, "SYNO.Core.Upgrade.Setting"),
        (.users, "SYNO.Core.User"),
        (.terminal, "SYNO.Core.Terminal"),
        (.power, "SYNO.Core.System"),
        (.connections, "SYNO.Core.CurrentConnection"),
        (.backup, Backup.api),
        (.backupLogs, BackupLog.api),
        (.snapshots, Snapshot.api),
        (.replication, Replication.api),
        (.notifications, Notify.api),
    ]
}
