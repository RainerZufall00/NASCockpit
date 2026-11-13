import Foundation
import Domain

// Hyper Backup. UNVERIFIED: observed in the DSM web UI and open-source clients
// (SYNO.Backup.Task list / backup / cancel). Verify against a real DSM 7.2.

extension DSMEndpoints {
    enum Backup {
        static let api = "SYNO.Backup.Task"

        /// UNVERIFIED: `additional` keys and the `task_list` response.
        static var list: DSMEndpoint<BackupTaskListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...1, params: [
                "additional": jsonArray(["last_bkp_time", "next_bkp_time", "last_bkp_result", "is_modified", "last_bkp_progress"]),
            ], timeout: 20)
        }

        /// UNVERIFIED: method `backup` with a numeric `task_id`.
        static func start(_ id: String) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "backup", versions: 1...1, params: ["task_id": id], isWrite: true, timeout: 30)
        }

        /// UNVERIFIED: method `cancel` with `task_id_list` as a JSON array of numbers.
        static func cancel(_ id: String) -> DSMEndpoint<EmptyResponse> {
            let list = Int(id).map { "[\($0)]" } ?? jsonArray([id])
            return DSMEndpoint(api: api, method: "cancel", versions: 1...1, params: ["task_id_list": list], isWrite: true, timeout: 30)
        }

        /// UNVERIFIED: method `status` with `blOnline=true` asks Hyper Backup to contact the destination
        /// (open-source clients send `blOnline=false` for a quick read). Decoded leniently.
        static func status(_ id: String) -> DSMEndpoint<BackupTaskStatusDTO> {
            DSMEndpoint(api: api, method: "status", versions: 1...1, params: ["task_id": id, "blOnline": "true"], timeout: 15)
        }

        static func control(_ control: BackupControl, id: String) -> DSMEndpoint<EmptyResponse> {
            control == .start ? start(id) : cancel(id)
        }
    }
}

/// SYNO.Backup.Task / status (UNVERIFIED). Looks for an online flag (`is_online`, `online`, `target_online`, …)
/// and for words like "offline" in the state fields, also one level down (e.g. `target: {status: "offline"}`).
struct BackupTaskStatusDTO: Decodable, Sendable {
    /// nil = the answer says nothing about the destination.
    let targetOnline: Bool?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        targetOnline = Self.online(in: c, depth: 0)
    }

    private static let stateKeys: Set<String> = ["state", "status", "target_status", "target_state", "online_status", "last_bkp_result"]

    private static func online(in c: KeyedDecodingContainer<AnyKey>, depth: Int) -> Bool? {
        var found: Bool?
        for key in c.allKeys {
            let name = key.stringValue.lowercased()
            if name.contains("online"), let value = c.lossyBool(key) {
                if !value { return false }
                found = true
            } else if stateKeys.contains(name), let value = c.lossyString(key), DSMMapping.isOfflineWord(value) {
                return false
            } else if depth < 2, let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key),
                      let value = online(in: nested, depth: depth + 1) {
                if !value { return false }
                found = true
            }
        }
        return found
    }
}

/// SYNO.Backup.Task / list (UNVERIFIED field names, decoded leniently).
struct BackupTaskListDTO: Decodable, Sendable {
    struct Task: Decodable, Sendable {
        let id: String
        let name: String
        /// e.g. "image:image_local", "image:cloud_c2" – whatever the NAS reports.
        let kind: String
        let status: String?
        let state: String?
        let lastResult: String?
        let lastTime: String?
        let nextTime: String?
        /// 0…1
        let progress: Double?

        private enum CodingKeys: String, CodingKey {
            case task_id, name, type, transfer_type, target_type, status, state
            case last_bkp_time, next_bkp_time, last_bkp_result, last_bkp_progress, progress, additional
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let extra = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .additional)
            func string(_ key: CodingKeys) -> String? { c.lossyString(key) ?? extra?.lossyString(key) }

            id = string(.task_id) ?? ""
            name = string(.name) ?? ""
            kind = [string(.transfer_type), string(.type), string(.target_type)].compactMap { $0 }.joined(separator: " ")
            status = string(.status)
            state = string(.state)
            lastResult = string(.last_bkp_result)
            lastTime = string(.last_bkp_time)
            nextTime = string(.next_bkp_time)
            progress = Self.progress(c, .last_bkp_progress) ?? Self.progress(c, .progress)
                ?? extra.flatMap { Self.progress($0, .last_bkp_progress) ?? Self.progress($0, .progress) }
        }

        /// A number (percent or fraction) or an object like `{"progress": 37}` / `{"percent": 37}`.
        private static func progress(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            var raw = c.lossyDouble(key)
            if raw == nil, let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key) {
                raw = nested.lossyDouble(AnyKey("progress")) ?? nested.lossyDouble(AnyKey("percent"))
            }
            guard let raw, raw >= 0 else { return nil }
            return raw > 1 ? min(1, raw / 100) : raw
        }
    }

    let tasks: [Task]

    private enum CodingKeys: String, CodingKey { case task_list, tasks }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = c.lossyArray(Task.self, .task_list)
        tasks = (list.isEmpty ? c.lossyArray(Task.self, .tasks) : list).filter { !$0.id.isEmpty }
    }
}

extension DSMMapping {
    static func backupTasks(_ dto: BackupTaskListDTO) -> [BackupTask] {
        dto.tasks.map { task in
            BackupTask(
                id: task.id,
                name: task.name.isEmpty ? String(localized: "Task \(task.id)") : task.name,
                destination: backupDestination(task.kind),
                activity: backupActivity(status: task.status, state: task.state, lastResult: task.lastResult, progress: task.progress),
                lastResult: backupResult(task.lastResult),
                lastBackup: task.lastTime.flatMap(parseBackupTime),
                nextBackup: task.nextTime.flatMap(parseBackupTime),
                // The list itself rarely says; `status` with blOnline fills this in (SynologyBackend).
                targetOnline: [task.state, task.status].contains { $0.map(isOfflineWord) == true } ? false : nil
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func backupDestination(_ raw: String) -> BackupDestination {
        let kind = raw.lowercased()
        let clouds: [(String, String)] = [
            ("c2", "Synology C2"), ("s3", "S3"), ("azure", "Azure"), ("google", "Google Drive"), ("gdrive", "Google Drive"),
            ("dropbox", "Dropbox"), ("onedrive", "OneDrive"), ("webdav", "WebDAV"), ("openstack", "OpenStack"),
            ("backblaze", "Backblaze B2"), ("hidrive", "HiDrive"), ("jd_cloud", "JD Cloud"), ("box", "Box"),
        ]
        if let match = clouds.first(where: { kind.contains($0.0) }) { return .cloud(match.1) }
        if kind.contains("cloud") { return .cloud(nil) }
        if kind.contains("remote") || kind.contains("rsync") || kind.contains("nas") { return .remoteNAS }
        if kind.contains("local") || kind.contains("usb") { return .local }
        return .other(raw)
    }

    /// "offline", "target_offline", "unavailable", "unreachable", "disconnected", "not_connected"…
    static func isOfflineWord(_ raw: String) -> Bool {
        let value = raw.lowercased()
        return ["offline", "unavailable", "unreachable", "disconnect", "not_connect", "not_found", "notfound"]
            .contains { value.contains($0) }
    }

    static func backupActivity(status: String?, state: String?, lastResult: String?, progress: Double?) -> BackupActivity {
        let value = [status, state].compactMap { $0?.lowercased() }.joined(separator: " ")
        if value.contains("suspend") || value.contains("pause") { return .suspended }
        if value.contains("wait") || value.contains("queue") { return .waiting }
        if value.contains("detect") || value.contains("integrity") || value.contains("check")
            || value.contains("delet") || value.contains("relink") || value.contains("rotat") {
            return .maintenance
        }
        if value.contains("backing") || value.contains("running") || value.contains("prepar") || value.contains("upload")
            || status?.lowercased() == "backup" || lastResult?.lowercased() == "backingup" {
            return .running(progress: progress)
        }
        return .idle
    }

    static func backupResult(_ raw: String?) -> BackupResult? {
        guard let value = raw?.lowercased(), !value.isEmpty else { return nil }
        if value.contains("partial") || value.contains("warn") { return .partial }
        if value.contains("fail") || value.contains("error") { return .failed }
        if value.contains("cancel") || value.contains("abort") || value.contains("suspend") { return .cancelled }
        if value == "done" || value.contains("success") || value == "finish" || value == "finished" { return .success }
        return nil
    }

    /// "2026/11/08 03:00", with or without seconds, or epoch seconds.
    static func parseBackupTime(_ string: String) -> Date? {
        if let seconds = Double(string), seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        if let date = parseLogDate(string) { return date }
        for format in ["yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
