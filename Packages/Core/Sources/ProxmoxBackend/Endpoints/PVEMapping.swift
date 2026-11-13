import Foundation
import Domain

/// Translates Proxmox DTOs into the platform-neutral domain models.
enum PVEMapping {
    // MARK: Dashboard

    static func snapshot(
        node: String, version: VersionDTO?, status: NodeStatusDTO?, storages: [StorageDTO], disks: [DiskDTO], rrd: [RRDPointDTO], capturedAt: Date = .now
    ) -> SystemSnapshot {
        let cpuModel = status?.cpuinfo?.model.map { $0.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "") }
        let cores = status?.cpuinfo?.cpus
        var model = node
        if let cpuModel, !cpuModel.isEmpty {
            model += " · " + cpuModel.trimmingCharacters(in: .whitespaces)
            if let cores { model += " (\(cores) threads)" }
        }
        let memoryTotal = status?.memory?.total
        let memoryUsage: Double? = {
            guard let total = memoryTotal, total > 0, let used = status?.memory?.used else { return nil }
            return min(1, Double(used) / Double(total))
        }()
        let last = rrd.last(where: { $0.netin != nil || $0.netout != nil })
        let network = last.map { NetworkThroughput(rxBytesPerSecond: max(0, $0.netin ?? 0), txBytesPerSecond: max(0, $0.netout ?? 0)) }

        var volumes: [VolumeInfo] = []
        if let root = status?.rootfs, let total = root.total, total > 0 {
            volumes.append(VolumeInfo(id: "rootfs", name: String(localized: "Root file system"), status: .normal, totalBytes: total, usedBytes: root.used ?? 0, fileSystem: nil))
        }
        for storage in storages where storage.enabled?.boolValue ?? true {
            let active = storage.active?.boolValue ?? true
            // Shared storages (NFS, PBS) appear on every node; their numbers are the same everywhere.
            volumes.append(VolumeInfo(
                id: storage.storage,
                name: storage.storage,
                status: active ? .normal : .warning,
                totalBytes: storage.total ?? 0,
                usedBytes: storage.used ?? 0,
                fileSystem: storage.type
            ))
        }

        let diskInfos = disks.map { disk in
            var name = disk.devpath.split(separator: "/").last.map(String.init) ?? disk.devpath
            if let type = disk.type?.uppercased(), !type.isEmpty { name += " (\(type))" }
            return DiskInfo(id: disk.devpath, name: name, model: disk.model, temperature: nil, status: diskHealth(disk.health))
        }

        return SystemSnapshot(
            model: model,
            osVersion: versionText(status?.pveversion, fallback: version?.version),
            uptime: status?.uptime,
            temperature: nil,
            temperatureWarning: false,
            cpuLoad: status?.cpu.map { min(1, max(0, $0)) },
            memoryUsage: memoryUsage,
            memoryTotalBytes: memoryTotal,
            network: network,
            diskReadBytesPerSecond: nil,
            diskWriteBytesPerSecond: nil,
            volumes: volumes,
            disks: diskInfos,
            capturedAt: capturedAt
        )
    }

    /// "pve-manager/8.2.2/9355359cd7afbae4" → "Proxmox VE 8.2.2"
    static func versionText(_ pveversion: String?, fallback: String?) -> String {
        if let pveversion {
            let parts = pveversion.split(separator: "/")
            if parts.count >= 2 { return "Proxmox VE \(parts[1])" }
        }
        if let fallback { return "Proxmox VE \(fallback)" }
        return "Proxmox VE"
    }

    /// SMART summary as Proxmox reports it: "PASSED", "OK", "FAILED!", "UNKNOWN" (no SMART).
    static func diskHealth(_ health: String?) -> HealthStatus {
        guard let health = health?.uppercased(), !health.isEmpty else { return .unknown }
        if health.hasPrefix("PASSED") || health == "OK" { return .normal }
        if health.contains("FAIL") { return .crashed }
        if health == "UNKNOWN" || health == "N/A" { return .unknown }
        return .warning
    }

    // MARK: Guests

    static func guests(_ resources: [ResourceDTO]) -> [VirtualGuest] {
        resources.compactMap { resource in
            guard let vmid = resource.vmid, let node = resource.node, let type = resource.type else { return nil }
            let kind: GuestKind
            switch type {
            case "qemu": kind = .virtualMachine
            case "lxc": kind = .container
            default: return nil
            }
            return VirtualGuest(
                id: resource.id ?? "\(type)/\(vmid)",
                vmid: vmid,
                name: resource.name ?? "VM \(vmid)",
                node: node,
                kind: kind,
                status: guestStatus(resource.status),
                cpuLoad: resource.cpu.map { min(1, max(0, $0)) },
                cores: resource.maxcpu.map { Int($0) },
                memoryBytes: resource.mem,
                maxMemoryBytes: resource.maxmem,
                diskBytes: resource.disk,
                maxDiskBytes: resource.maxdisk,
                uptime: resource.uptime.flatMap { $0 > 0 ? $0 : nil },
                isTemplate: resource.template?.boolValue ?? false,
                lock: resource.lock.flatMap { $0.isEmpty ? nil : $0 },
                haState: resource.hastate.flatMap { $0.isEmpty || $0 == "ignored" ? nil : $0 },
                tags: (resource.tags ?? "").split(whereSeparator: { $0 == ";" || $0 == "," }).map(String.init)
            )
        }
        .sorted { $0.vmid < $1.vmid }
    }

    /// Routable addresses of a guest, IPv4 before IPv6; loopback and link-local are left out.
    static func addresses(agent: AgentInterfacesDTO?, container: [ContainerInterfaceDTO]?) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        func add(_ raw: String?) {
            guard var address = raw?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return }
            if let slash = address.firstIndex(of: "/") { address = String(address[..<slash]) }
            let lower = address.lowercased()
            if lower == "::1" || lower.hasPrefix("127.") || lower.hasPrefix("fe80") || lower.hasPrefix("169.254.") { return }
            if address.contains(":") {
                if !v6.contains(address) { v6.append(address) }
            } else if !v4.contains(address) {
                v4.append(address)
            }
        }
        for interface in agent?.result ?? [] where interface.name != "lo" {
            for entry in interface.addresses ?? [] { add(entry.address) }
        }
        for interface in container ?? [] where interface.name != "lo" {
            add(interface.inet)
            add(interface.inet6)
        }
        return v4 + v6
    }

    static func guestStatus(_ raw: String?) -> GuestStatus {
        switch raw?.lowercased() {
        case "running": .running
        case "stopped": .stopped
        case "paused": .paused
        case "suspended", "prelaunch": .suspended
        default: .unknown
        }
    }

    // MARK: Updates

    static func updates(_ packages: [AptUpdateDTO], serverID: ServerID) -> [UpdateItem] {
        packages.compactMap { package in
            guard let name = package.package, let version = package.version else { return nil }
            return UpdateItem(
                serverID: serverID,
                kind: .package(id: name),
                name: name,
                installedVersion: package.oldVersion,
                availableVersion: version,
                requiresReboot: name.contains("kernel") || name.hasPrefix("linux-image") || name.hasPrefix("pve-firmware")
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Backups

    /// One `BackupTask` per vzdump job. The last run is the newest vzdump task that fits the job
    /// (same node when the job is bound to one; task ID empty or one of the job's guests).
    static func backupTasks(jobs: [BackupJobDTO], tasks: [TaskListEntryDTO], archives: [ContentDTO]) -> [BackupTask] {
        let finished = tasks.filter { !$0.isRunning }.sorted { ($0.starttime ?? 0) > ($1.starttime ?? 0) }
        let running = tasks.filter(\.isRunning)
        return jobs.map { job in
            let vmids = job.vmids
            func fits(_ task: TaskListEntryDTO) -> Bool {
                if let node = job.node, let taskNode = task.node, node != taskNode { return false }
                guard let id = task.id, !id.isEmpty, let vmid = Int(id) else { return true }
                return job.backsUpAll || vmids.contains(vmid)
            }
            let last = finished.first(where: fits)
            let isRunning = running.contains(where: fits)
            let newestArchive = archives
                .filter { job.backsUpAll || $0.vmid.map(vmids.contains) ?? false }
                .compactMap(\.ctime).max().map { Date(timeIntervalSince1970: $0) }
            let lastRun = last?.starttime.map { Date(timeIntervalSince1970: $0) }
            let name: String = {
                if let comment = job.comment, !comment.isEmpty { return comment }
                if job.backsUpAll { return String(localized: "All guests") }
                let ids = vmids.sorted().map(String.init).joined(separator: ", ")
                return ids.isEmpty ? String(localized: "Backup job") : String(localized: "Guests \(ids)")
            }()
            return BackupTask(
                id: job.id,
                name: name,
                destination: .other(job.storage ?? ""),
                activity: isRunning ? .running(progress: nil) : (job.enabled ? .idle : .suspended),
                lastResult: last.map { $0.succeeded ? .success : .failed },
                lastBackup: [lastRun, newestArchive].compactMap { $0 }.max(),
                nextBackup: job.enabled ? job.nextRun : nil
            )
        }
    }

    static func backupLog(_ tasks: [TaskListEntryDTO], query: LogQuery) -> LogPage {
        let entries = tasks.enumerated().map { index, task -> LogEntry in
            let date = task.starttime.map { Date(timeIntervalSince1970: $0) }
            let level: LogLevel = task.isRunning ? .info : task.succeeded ? .info : .error
            var text: String
            if task.isRunning {
                text = String(localized: "Backup running")
            } else if task.succeeded {
                text = String(localized: "Backup finished successfully")
            } else {
                text = String(localized: "Backup failed: \(task.status ?? "")")
            }
            if let id = task.id, !id.isEmpty { text += " · " + String(localized: "guest \(id)") }
            if let start = task.starttime, let end = task.endtime, end > start {
                text += " · " + Duration.seconds(end - start).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
            }
            return LogEntry(id: query.offset + index, date: date, level: level, category: "vzdump", user: task.user, message: text)
        }
        let filtered = entries.filter { query.matches($0) && matchesKeyword($0, query.keyword) }
        return LogPage(entries: filtered, total: query.offset + tasks.count, nextOffset: tasks.count < query.limit ? nil : query.offset + tasks.count)
    }

    // MARK: Logs

    /// Formatters are not Sendable; a fresh one per call is cheap enough for a log page.
    static func syslogFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss"
        return formatter
    }

    static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// "Nov 10 12:00:01 pve pvedaemon[1234]: <root@pam> successful auth for user 'root@pam'"
    static func syslogEntry(_ line: String, id: Int, now: Date = .now, calendar: Calendar = .current) -> LogEntry {
        var rest = Substring(line)
        var date: Date?
        // journalctl "short" (no year) or ISO timestamps.
        if let iso = rest.split(separator: " ", maxSplits: 1).first, iso.contains("T"),
           let parsed = isoFormatter().date(from: String(iso)) ?? ISO8601DateFormatter().date(from: String(iso)) {
            date = parsed
            rest = rest.dropFirst(iso.count).drop(while: { $0 == " " })
        } else {
            let parts = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if parts.count >= 4, let parsed = syslogFormatter().date(from: "\(parts[0]) \(parts[1]) \(parts[2].prefix(8))") {
                var components = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: parsed)
                components.year = calendar.component(.year, from: now)
                if let candidate = calendar.date(from: components) {
                    // Lines from December read in January belong to the previous year.
                    date = candidate > now.addingTimeInterval(86_400) ? calendar.date(byAdding: .year, value: -1, to: candidate) : candidate
                }
                rest = parts[3]
            }
        }
        // "<host> <unit>[pid]: <message>"
        var category = "syslog"
        var message = String(rest)
        let hostSplit = rest.split(separator: " ", maxSplits: 1)
        if hostSplit.count == 2 {
            let afterHost = hostSplit[1]
            if let colon = afterHost.firstIndex(of: ":"), !afterHost[..<colon].contains(" ") {
                var unit = String(afterHost[..<colon])
                if let bracket = unit.firstIndex(of: "[") { unit = String(unit[..<bracket]) }
                category = unit
                message = afterHost[afterHost.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let lower = message.lowercased()
        let level: LogLevel = lower.contains("error") || lower.contains("fail") || lower.contains("fatal") || lower.contains("critical")
            ? .error
            : lower.contains("warn") || lower.contains("denied") ? .warning : .info
        return LogEntry(id: id, date: date, level: level, category: category, user: nil, message: message)
    }

    static func logPage(_ lines: [SyslogLineDTO], total: Int?, query: LogQuery, onlyAuthentication: Bool) -> LogPage {
        var entries = lines.enumerated().map { index, line in
            syslogEntry(line.t ?? "", id: line.n ?? (query.offset + index))
        }
        if onlyAuthentication {
            entries = entries.filter { $0.message.localizedCaseInsensitiveContains("auth") || $0.message.localizedCaseInsensitiveContains("login") }
        }
        entries = entries.filter { query.matches($0) && matchesKeyword($0, query.keyword) }
        let next = query.offset + lines.count
        let totalCount = total ?? next
        return LogPage(entries: entries, total: totalCount, nextOffset: lines.isEmpty || next >= totalCount ? nil : next)
    }

    private static func matchesKeyword(_ entry: LogEntry, _ keyword: String?) -> Bool {
        guard let keyword, !keyword.isEmpty else { return true }
        return entry.message.localizedCaseInsensitiveContains(keyword) || entry.category.localizedCaseInsensitiveContains(keyword)
    }
}

extension PVEMapping {
    static func snapshots(_ list: [SnapshotDTO]) -> [GuestSnapshot] {
        list.filter { $0.name != "current" }
            .map { dto in
                GuestSnapshot(
                    name: dto.name,
                    description: (dto.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    date: dto.snaptime?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                    includesMemory: dto.vmstate?.boolValue ?? false,
                    parent: dto.parent
                )
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
