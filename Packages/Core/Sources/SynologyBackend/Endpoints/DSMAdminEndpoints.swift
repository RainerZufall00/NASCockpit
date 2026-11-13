import Foundation
import Domain

// Control Panel (UNVERIFIED: observed in the DSM web UI / open-source clients) and
// File Station (documented in Synology's File Station API guide).

extension DSMEndpoints {
    /// Paths stay readable: "/photo", not "\/photo".
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func jsonArray(_ values: [String]) -> String {
        let data = (try? jsonEncoder.encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    enum UpgradeSetting {
        static let api = "SYNO.Core.Upgrade.Setting"

        /// UNVERIFIED: keys `autoupdate_enable`, `autoupdate_type`, `schedule`.
        static var get: DSMEndpoint<UpdateSettingsDTO> {
            DSMEndpoint(api: api, method: "get", versions: 1...4)
        }

        static func set(_ policy: UpdatePolicy) -> DSMEndpoint<EmptyResponse> {
            var params = ["autoupdate_enable": policy == .notifyOnly ? "false" : "true"]
            if policy != .notifyOnly {
                params["autoupdate_type"] = jsonString(policy == .all ? "all" : "hotfix-security")
            }
            return DSMEndpoint(api: api, method: "set", versions: 1...4, params: params, isWrite: true, timeout: 30)
        }
    }

    enum User {
        static let api = "SYNO.Core.User"

        /// UNVERIFIED: `additional` and the `expired` field ("normal" / "now" / date).
        static var list: DSMEndpoint<UserListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...1, params: [
                "offset": "0",
                "limit": "-1",
                "additional": jsonArray(["email", "description", "expired"]),
            ])
        }

        /// UNVERIFIED: `expired="now"` disables the account, `"normal"` enables it again.
        static func set(_ name: String, disabled: Bool) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "set", versions: 1...1, params: [
                "name": jsonString(name),
                "expired": jsonString(disabled ? "now" : "normal"),
            ], isWrite: true, timeout: 30)
        }
    }

    enum Terminal {
        static let api = "SYNO.Core.Terminal"

        static var get: DSMEndpoint<TerminalDTO> {
            DSMEndpoint(api: api, method: "get", versions: 1...3)
        }

        /// UNVERIFIED: `enable_ssh`, `ssh_port`. The port is sent along so DSM keeps it.
        static func set(sshEnabled: Bool, port: Int?) -> DSMEndpoint<EmptyResponse> {
            var params = ["enable_ssh": sshEnabled ? "true" : "false"]
            if let port { params["ssh_port"] = String(port) }
            return DSMEndpoint(api: api, method: "set", versions: 1...3, params: params, isWrite: true, timeout: 30)
        }
    }

    enum CurrentConnection {
        static let api = "SYNO.Core.CurrentConnection"

        static var list: DSMEndpoint<ConnectionListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...1, params: [
                "start": "0",
                "limit": "100",
                "sort_by": jsonString("time"),
                "sort_direction": jsonString("DESC"),
            ])
        }
    }

    enum Power {
        static let api = "SYNO.Core.System"

        /// UNVERIFIED: `reboot` / `shutdown` on SYNO.Core.System.
        static func perform(_ action: PowerAction) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: action == .restart ? "reboot" : "shutdown", versions: 1...1,
                        params: ["force": "false", "local": "true"], isWrite: true, timeout: 30)
        }
    }

    // MARK: File Station (official API)

    enum FileStation {
        static let listAPI = "SYNO.FileStation.List"
        static let copyMoveAPI = "SYNO.FileStation.CopyMove"
        static let createFolderAPI = "SYNO.FileStation.CreateFolder"
        static let deleteAPI = "SYNO.FileStation.Delete"

        static var shares: DSMEndpoint<FileListDTO> {
            DSMEndpoint(api: listAPI, method: "list_share", versions: 2...2, params: [
                "offset": "0",
                "limit": "1000",
                "sort_by": jsonString("name"),
                "additional": jsonArray(["time"]),
            ], documentation: .official)
        }

        static func list(_ folder: String, offset: Int) -> DSMEndpoint<FileListDTO> {
            DSMEndpoint(api: listAPI, method: "list", versions: 2...2, params: [
                "folder_path": jsonString(folder),
                "offset": String(offset),
                "limit": String(pageSize),
                "sort_by": jsonString("name"),
                "filetype": jsonString("all"),
                "additional": jsonArray(["size", "time"]),
            ], documentation: .official, timeout: 20)
        }

        static let pageSize = 1000

        /// Existing items with the same name are skipped (`overwrite=false`), never replaced.
        static func start(_ path: String, to destination: String, mode: TransferMode) -> DSMEndpoint<TaskStartDTO> {
            DSMEndpoint(api: copyMoveAPI, method: "start", versions: 3...3, params: [
                "path": jsonArray([path]),
                "dest_folder_path": jsonString(destination),
                "overwrite": "false",
                "remove_src": mode == .move ? "true" : "false",
                "accurate_progress": "true",
            ], isWrite: true, documentation: .official, timeout: 30)
        }

        static func status(task: String) -> DSMEndpoint<TaskStatusDTO> {
            DSMEndpoint(api: copyMoveAPI, method: "status", versions: 3...3, params: ["taskid": jsonString(task)],
                        documentation: .official, timeout: 15)
        }

        /// Folders are deleted with their contents (`recursive=true`), like File Station does.
        static func startDelete(_ paths: [String]) -> DSMEndpoint<TaskStartDTO> {
            DSMEndpoint(api: deleteAPI, method: "start", versions: 2...2, params: [
                "path": jsonArray(paths),
                "accurate_progress": "true",
                "recursive": "true",
            ], isWrite: true, documentation: .official, timeout: 30)
        }

        static func deleteStatus(task: String) -> DSMEndpoint<TaskStatusDTO> {
            DSMEndpoint(api: deleteAPI, method: "status", versions: 2...2, params: ["taskid": jsonString(task)],
                        documentation: .official, timeout: 15)
        }

        static func createFolder(_ name: String, in folder: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: createFolderAPI, method: "create", versions: 2...2, params: [
                "folder_path": jsonArray([folder]),
                "name": jsonArray([name]),
                "force_parent": "false",
            ], isWrite: true, documentation: .official, timeout: 30)
        }
    }
}
