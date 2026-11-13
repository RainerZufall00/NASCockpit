import Foundation
import Domain

// Snapshot Replication. UNVERIFIED: request shapes from the open-source synology-api library
// (SYNO.Core.Share.Snapshot list/create, SYNO.DR.Plan list/sync). Verify against a real DSM 7.2.

extension DSMEndpoints {
    enum Snapshot {
        static let api = "SYNO.Core.Share.Snapshot"

        /// `name` is the plain share name; `limit=-1` lists all.
        static func list(share: String) -> DSMEndpoint<SnapshotListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...2, params: [
                "name": share,
                "filter": #"{"attr":[]}"#,
                "additional": jsonArray(["desc", "lock", "schedule_snapshot", "worm_lock"]),
                "offset": "0",
                "limit": "-1",
            ], timeout: 20)
        }

        /// `snapinfo` is a JSON object; DSM answers with the new snapshot's name.
        static func create(share: String, description: String) -> DSMEndpoint<EmptyResponse> {
            let info = SnapInfo(desc: description, lock: false)
            let json = (try? jsonEncoder.encode(info)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return DSMEndpoint(api: api, method: "create", versions: 1...1, params: [
                "snapinfo": json,
                "name": share,
            ], isWrite: true, timeout: 60)
        }

        private struct SnapInfo: Encodable {
            let desc: String
            let lock: Bool
        }
    }

    enum Replication {
        static let api = "SYNO.DR.Plan"

        static var list: DSMEndpoint<ReplicationPlanListDTO> {
            DSMEndpoint(api: api, method: "list", versions: 1...1, params: [
                "additional": jsonArray(["sync_policy", "sync_report", "main_site_info", "dr_site_info", "can_do", "op_info", "last_op_info"]),
            ], timeout: 20)
        }

        /// `nowait` returns right away; the sync continues on the NAS.
        static func sync(planID: String, sendEncrypted: Bool) -> DSMEndpoint<EmptyResponse> {
            DSMEndpoint(api: api, method: "sync", versions: 1...1, params: [
                "plan_id": planID,
                "nowait": "true",
                "auto_remove": "true",
                "is_snapshot_locked": "false",
                "is_send_encrypted": sendEncrypted ? "true" : "false",
                "sync_description": "NAS Cockpit",
            ], isWrite: true, timeout: 30)
        }
    }
}

/// SYNO.Core.Share.Snapshot / list
struct SnapshotListDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let time: String
        let desc: String?
        let lock: Bool?
        let wormLock: Bool?
        let scheduled: Bool?

        private enum CodingKeys: String, CodingKey { case time, desc, lock, worm_lock, schedule_snapshot }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = c.lossyString(.time) ?? ""
            desc = c.lossyString(.desc)
            lock = c.lossyBool(.lock)
            wormLock = c.lossyBool(.worm_lock)
            scheduled = c.lossyBool(.schedule_snapshot)
        }
    }

    let snapshots: [Item]

    private enum CodingKeys: String, CodingKey { case snapshots }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = c.lossyArray(Item.self, .snapshots).filter { !$0.time.isEmpty }
    }
}

/// SYNO.DR.Plan / list (fields from the synology-api documentation example)
struct ReplicationPlanListDTO: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        let id: String
        let targetID: String?
        let role: String?
        let isToLocal: Bool?
        let mainSite: Site?
        let drSite: Site?
        let canSync: Bool?
        let progress: Double?
        let isSyncing: Bool
        let lastSync: Date?
        let lastSucceeded: Bool?
        let nextSync: Date?
        let policyEnabled: Bool?
        let sendEncrypted: Bool
        let failCount: Int?

        struct Site: Decodable, Sendable {
            let hostname: String?
            let targetName: String?

            private enum CodingKeys: String, CodingKey { case hostname, target_name, target_id }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hostname = c.lossyString(.hostname)
                targetName = c.lossyString(.target_name) ?? c.lossyString(.target_id)
            }
        }

        private enum CodingKeys: String, CodingKey { case plan_id, target_id, role_str, is_to_local, additional }
        private enum Additional: String, CodingKey { case main_site_info, dr_site_info, can_do, op_info, last_op_info, sync_policy, sync_report }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.plan_id) ?? ""
            targetID = c.lossyString(.target_id)
            role = c.lossyString(.role_str)
            isToLocal = c.lossyBool(.is_to_local)
            let extra = try? c.nestedContainer(keyedBy: Additional.self, forKey: .additional)
            mainSite = try? extra?.decodeIfPresent(Site.self, forKey: .main_site_info)
            drSite = try? extra?.decodeIfPresent(Site.self, forKey: .dr_site_info)

            let canDo = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .can_do)
            canSync = canDo?.lossyBool(AnyKey("can_sync"))

            let op = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .op_info)
            let opProgress = try? op?.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("op_progress"))
            let percentage = opProgress?.lossyDouble(AnyKey("percentage"))
            progress = percentage.flatMap { $0 >= 0 ? min(1, $0 / 100) : nil }

            let report = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .sync_report)
            let recordKey = AnyKey("syncing_record")
            let syncingRecord = report.map { $0.contains(recordKey) && (try? $0.decodeNil(forKey: recordKey)) == false } ?? false
            isSyncing = syncingRecord || progress != nil
            failCount = report?.lossyInt(AnyKey("fail_sync_count"))

            let last = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .last_op_info)
            lastSync = last?.lossyDouble(AnyKey("update_time")).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            lastSucceeded = last?.lossyBool(AnyKey("is_success"))

            let policy = try? extra?.nestedContainer(keyedBy: AnyKey.self, forKey: .sync_policy)
            policyEnabled = policy?.lossyBool(AnyKey("enabled"))
            nextSync = policy?.lossyDouble(AnyKey("next_trigger_time")).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            sendEncrypted = policy?.lossyBool(AnyKey("is_send_encrypted")) ?? false
        }
    }

    let plans: [Plan]

    private enum CodingKeys: String, CodingKey { case plans }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = c.lossyArray(Plan.self, .plans).filter { !$0.id.isEmpty }
    }
}

extension DSMMapping {
    static func snapshots(_ dto: SnapshotListDTO, share: String) -> ShareSnapshots {
        ShareSnapshots(share: share, snapshots: dto.snapshots.map { item in
            SnapshotItem(
                id: item.time,
                date: parseSnapshotName(item.time),
                description: item.desc.flatMap { $0.isEmpty ? nil : $0 },
                isLocked: item.lock ?? false,
                isImmutable: item.wormLock ?? false,
                isScheduled: item.scheduled ?? false
            )
        })
    }

    /// "GMT+01-2026.11.08-03.00.02" (also "GMT-05:30-…") → Date.
    static func parseSnapshotName(_ name: String) -> Date? {
        guard name.hasPrefix("GMT"),
              let range = name.range(of: #"\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) else { return nil }
        var offset = name[name.index(name.startIndex, offsetBy: 3)..<range.lowerBound]
        if offset.hasSuffix("-") { offset = offset.dropLast() }
        var seconds = 0
        if let sign = offset.first, sign == "+" || sign == "-" {
            let digits = offset.dropFirst().split(separator: ":")
            let hours = Int(digits.first ?? "") ?? 0
            let minutes = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
            seconds = (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: seconds)
        formatter.dateFormat = "yyyy.MM.dd-HH.mm.ss"
        return formatter.date(from: String(name[range]))
    }

    static func replicationPlans(_ dto: ReplicationPlanListDTO) -> [ReplicationPlan] {
        dto.plans.map { plan in
            let isDestination = plan.role?.lowercased().contains("dr") == true
            let own = isDestination ? plan.drSite : plan.mainSite
            let other = isDestination ? plan.mainSite : plan.drSite
            return ReplicationPlan(
                id: plan.id,
                name: own?.targetName ?? plan.targetID ?? plan.id,
                role: isDestination ? .destination : .source,
                partner: plan.isToLocal == true ? nil : other?.hostname,
                isSyncing: plan.isSyncing,
                progress: plan.progress,
                lastSync: plan.lastSync,
                lastSyncSucceeded: plan.lastSucceeded,
                nextSync: plan.policyEnabled == false ? nil : plan.nextSync,
                failedSyncCount: plan.failCount ?? 0,
                canSync: !isDestination && (plan.canSync ?? true)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
