import Foundation
import Domain

// Phase 2: write endpoints and Container Manager.
//
// UNVERIFIED: all of these are observed in the DSM web UI / open-source clients, not documented by
// Synology. Check method names, parameters and response shapes against a real DSM 7.2 before release.

extension DSMEndpoints {
    /// DSM expects some string parameters JSON-encoded (`name="\"plex\""`).
    static func jsonString(_ value: String) -> String {
        let data = (try? jsonEncoder.encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    enum PackageControl {
        static let api = "SYNO.Core.Package.Control"

        static func start(_ id: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "start", versions: 1...1, params: ["id": id], isWrite: true, timeout: 60)
        }

        static func stop(_ id: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "stop", versions: 1...1, params: ["id": id], isWrite: true, timeout: 60)
        }
    }

    enum PackageInstallation {
        static let api = "SYNO.Core.Package.Installation"
        /// DSM 7.4 answers `install`/`upgrade` with 103 in the highest version, so each call is tried per version,
        /// lowest first (what Package Center's own scripts and open-source clients use).
        static let versions = [1, 2]

        /// UNVERIFIED (Package Center flow): step 1 downloads the new .spk; returns a task id to poll with `status`.
        static func download(_ id: String, url: String, checksum: String?, size: Int64?, version: Int) -> DSMEndpoint<TaskStartDTO> {
            var params = ["name": id, "url": url, "operation": "upgrade", "type": "0", "blqinst": "true"]
            if let checksum { params["checksum"] = checksum }
            if let size { params["filesize"] = String(size) }
            return DSMEndpoint(api: api, method: "install", versions: version...version, params: params, isWrite: true, timeout: 60)
        }

        /// UNVERIFIED: step 2 installs the downloaded package over the installed one and starts it again.
        static func upgrade(task: String, version: Int) -> DSMEndpoint<TaskStartDTO> {
            DSMEndpoint(api: api, method: "upgrade", versions: version...version, params: [
                "task_id": task, "type": "0", "check_codesign": "false", "force": "false",
                "installrunpackage": "true", "extra_values": "{}",
            ], isWrite: true, timeout: 120)
        }

        /// Older shortcut: upgrade by name.
        static func upgrade(_ id: String, version: Int) -> DSMEndpoint<TaskStartDTO> {
            DSMEndpoint(api: api, method: "upgrade", versions: version...version, params: ["name": id, "blqinst": "true"], isWrite: true, timeout: 60)
        }

        static func status(task: String, version: Int) -> DSMEndpoint<TaskStatusDTO> {
            DSMEndpoint(api: api, method: "status", versions: version...version, params: ["task_id": task], timeout: 15)
        }
    }

    enum SystemUpgrade {
        static let downloadAPI = "SYNO.Core.Upgrade.Server.Download"
        static let api = "SYNO.Core.Upgrade"

        static var download: DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: downloadAPI, method: "start", versions: 1...2, isWrite: true, timeout: 30)
        }

        static var downloadProgress: DSMEndpoint<TaskStatusDTO> {
            DSMEndpoint(api: downloadAPI, method: "progress", versions: 1...2, timeout: 15)
        }

        /// Installs the downloaded update. DSM reboots on its own afterwards.
        static var install: DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "start", versions: 1...2, params: ["updateType": jsonString("all")], isWrite: true, timeout: 60)
        }
    }

    enum Docker {
        static let containerAPI = "SYNO.Docker.Container"
        static let projectAPI = "SYNO.Docker.Project"

        static var containers: DSMEndpoint<ContainerListDTO> {
            DSMEndpoint(api: containerAPI, method: "list", versions: 1...1, params: ["limit": "-1", "offset": "0", "type": jsonString("all")])
        }

        static var resources: DSMEndpoint<ContainerResourceDTO> {
            DSMEndpoint(api: "SYNO.Docker.Container.Resource", method: "get", versions: 1...1)
        }

        static func control(_ action: ContainerAction, name: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: containerAPI, method: action.rawValue, versions: 1...1, params: ["name": jsonString(name)], isWrite: true, timeout: 60)
        }

        static func logs(_ name: String, limit: Int) -> DSMEndpoint<ContainerLogDTO> {
            DSMEndpoint(
                api: "SYNO.Docker.Container.Log",
                method: "get",
                versions: 1...1,
                params: ["name": jsonString(name), "limit": String(limit), "offset": "0", "sort_dir": jsonString("DESC")],
                timeout: 20
            )
        }

        static var projects: DSMEndpoint<ProjectListDTO> {
            DSMEndpoint(api: projectAPI, method: "list", versions: 1...1)
        }

        /// MVP: start, stop, rebuild ("build" recreates the containers from compose.yaml).
        static func control(_ action: ProjectAction, id: String) -> DSMEndpoint<EmptyResponse> {
            let method = switch action {
            case .start: "start"
            case .stop: "stop"
            case .rebuild: "build"
            }
            return DSMEndpoint(api: projectAPI, method: method, versions: 1...1, params: ["id": jsonString(id)], isWrite: true, timeout: 300)
        }
    }
}
