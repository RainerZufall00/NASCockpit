import Foundation
import Domain

/// Translates DSM DTOs into platform-neutral domain models.
enum DSMMapping {
    /// The interface whose address is one of the profile's hosts, otherwise the first one with an address.
    static func wakeOnLAN(_ info: NetworkInfoDTO, hosts: [String]) -> WakeOnLANConfig? {
        let usable = info.interfaces.filter { $0.mac.flatMap(MACAddress.init) != nil }
        let chosen = usable.first { iface in hosts.contains { $0.caseInsensitiveCompare(iface.address ?? "") == .orderedSame } }
            ?? usable.first { !($0.address ?? "").isEmpty }
            ?? usable.first
        guard let chosen, let mac = chosen.mac.flatMap(MACAddress.init) else { return nil }
        let broadcast = chosen.address.flatMap { address in chosen.mask.flatMap { WakeOnLAN.broadcast(address: address, netmask: $0) } }
        return WakeOnLANConfig(mac: mac, broadcast: broadcast)
    }

    static func health(_ status: String?) -> HealthStatus {
        guard let status = status?.lowercased(), !status.isEmpty else { return .unknown }
        if status.contains("crash") || status.contains("fail") { return .crashed }
        if status.contains("degrad") { return .degraded }
        if status.contains("normal") || status == "healthy" { return .normal }
        if status.contains("warn") || status.contains("attention") || status.contains("abnormal") { return .warning }
        return .unknown
    }

    /// DSM reports uptime as "H:M:S" (hours can exceed 24) or as seconds.
    static func uptime(_ value: String?) -> TimeInterval? {
        guard let value, !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func snapshot(info: SystemInfoDTO?, utilization: UtilizationDTO?, storage: StorageDTO?, capturedAt: Date = .now) -> SystemSnapshot {
        let cpu = utilization?.cpu.map { cpu in
            min(1, ((cpu.user ?? 0) + (cpu.system ?? 0) + (cpu.other ?? 0)) / 100)
        }
        let memoryUsage = utilization?.memory?.realUsage.map { min(1, $0 / 100) }
        let memoryKiB = utilization?.memory?.memorySize ?? utilization?.memory?.totalReal
        let memoryTotal = memoryKiB.map { $0 * 1024 } ?? info?.ramSizeMB.map { $0 * 1024 * 1024 }

        let networkEntries = utilization?.network ?? []
        let network: NetworkThroughput? = {
            if let total = networkEntries.first(where: { $0.device == "total" }) {
                return NetworkThroughput(rxBytesPerSecond: total.rx ?? 0, txBytesPerSecond: total.tx ?? 0)
            }
            guard !networkEntries.isEmpty else { return nil }
            return NetworkThroughput(
                rxBytesPerSecond: networkEntries.compactMap(\.rx).reduce(0, +),
                txBytesPerSecond: networkEntries.compactMap(\.tx).reduce(0, +)
            )
        }()

        let volumes = (storage?.volumes ?? []).map { volume in
            VolumeInfo(
                id: volume.id,
                name: volume.displayName ?? volumeName(id: volume.id, path: volume.path),
                status: health(volume.status),
                totalBytes: volume.totalBytes ?? 0,
                usedBytes: volume.usedBytes ?? 0,
                fileSystem: volume.fileSystem
            )
        }

        let disks = (storage?.disks ?? []).map { disk in
            let smart = health(disk.smartStatus)
            let status = health(disk.status)
            return DiskInfo(
                id: disk.id,
                name: disk.longName ?? disk.name ?? disk.id,
                model: disk.model?.trimmingCharacters(in: .whitespaces),
                temperature: disk.temperature,
                status: smart.isProblem ? smart : status
            )
        }

        return SystemSnapshot(
            model: info?.model ?? "Synology NAS",
            osVersion: info?.firmwareVersion ?? "DSM",
            uptime: uptime(info?.upTime),
            temperature: info?.temperature,
            temperatureWarning: info?.temperatureWarning ?? false,
            cpuLoad: cpu,
            memoryUsage: memoryUsage,
            memoryTotalBytes: memoryTotal,
            network: network,
            diskReadBytesPerSecond: utilization?.disk?.total?.readBytes,
            diskWriteBytesPerSecond: utilization?.disk?.total?.writeBytes,
            volumes: volumes,
            disks: disks,
            capturedAt: capturedAt
        )
    }

    /// "volume_1" / "/volume1" → "Volume 1"
    static func volumeName(id: String, path: String?) -> String {
        let source = path ?? id
        let digits = source.filter(\.isNumber)
        return digits.isEmpty ? source : String(localized: "Volume \(digits)")
    }

    static func packageStatus(_ status: String?) -> PackageStatus {
        switch status?.lowercased() {
        case "running", "start", "started": .running
        case "stop", "stopped": .stopped
        case "starting", "stopping", "installing", "upgrading", "repairing": .transitioning
        case "broken", "error", "repair": .broken
        default: .unknown
        }
    }

    static func packages(_ installed: PackageListDTO, serverCatalog: ServerPackageListDTO?) -> [PackageItem] {
        let available = Dictionary(
            (serverCatalog?.packages ?? []).compactMap { package in package.version.map { (package.id, $0) } },
            uniquingKeysWith: { first, second in VersionComparator.isNewer(second, than: first) ? second : first }
        )
        return installed.packages.map { package in
            let version = package.version ?? ""
            let newer = available[package.id].flatMap { VersionComparator.isNewer($0, than: version) ? $0 : nil }
            return PackageItem(
                id: package.id,
                name: package.name ?? package.id,
                version: version,
                status: packageStatus(package.status),
                availableVersion: newer,
                summary: package.description
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func systemUpdate(_ check: UpgradeCheckDTO, installedVersion: String?, serverID: ServerID) -> UpdateItem? {
        guard check.available, let version = check.version, !version.isEmpty else { return nil }
        return UpdateItem(
            serverID: serverID,
            kind: .system,
            name: "DSM",
            installedVersion: installedVersion,
            availableVersion: version,
            requiresReboot: check.reboot.map { $0.lowercased() != "none" } ?? true
        )
    }

    static func logLevel(_ level: String?) -> LogLevel {
        switch level?.lowercased() {
        case "warn", "warning": .warning
        case "err", "error", "crit", "critical", "alert", "emerg": .error
        default: .info
        }
    }

    static func dsmLevel(_ level: LogLevel) -> String {
        switch level {
        case .info: "info"
        case .warning: "warn"
        case .error: "err"
        }
    }

    static func logPage(_ dto: LogListDTO, query: LogQuery) -> LogPage {
        let fallbackCategory = query.source == .connection ? "Connection" : "System"
        let entries = dto.items.enumerated().map { index, item in
            LogEntry(
                id: query.offset + index,
                date: item.time.flatMap(parseLogDate),
                level: logLevel(item.level),
                category: item.logType.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackCategory,
                user: item.who,
                message: item.message ?? ""
            )
        }
        return page(entries, rawCount: dto.items.count, total: dto.total, query: query)
    }

    /// Filters on the device and stops paging once a newest-first page reaches entries older than `from`.
    static func page(_ entries: [LogEntry], rawCount: Int, total: Int?, query: LogQuery) -> LogPage {
        let next = query.offset + rawCount
        let total = total ?? (rawCount < query.limit ? next : next + 1)
        var hasMore = rawCount > 0 && next < total
        let dates = entries.compactMap(\.date)
        if let from = query.from, let newest = dates.first, let oldest = dates.last, newest >= oldest, oldest < from {
            hasMore = false
        }
        return LogPage(entries: entries.filter(query.matches), total: total, nextOffset: hasMore ? next : nil)
    }

    /// Hyper Backup writes "[Local][Task] message", "[Network][Task] message" or "[Task] message".
    static func backupLogPage(_ dto: BackupLogListDTO, query: LogQuery) -> LogPage {
        let entries = dto.items.enumerated().map { index, item in
            let (task, message) = splitBackupEvent(item.event ?? "")
            return LogEntry(
                id: query.offset + index,
                date: item.time.flatMap(parseBackupTime),
                level: logLevel(item.level),
                category: task ?? "Hyper Backup",
                user: item.user,
                message: message
            )
        }
        return page(entries, rawCount: dto.items.count, total: dto.total, query: query)
    }

    static func splitBackupEvent(_ event: String) -> (task: String?, message: String) {
        var rest = Substring(event)
        func bracket() -> String? {
            guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { return nil }
            let value = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            return value
        }
        var task = bracket()
        if let first = task, ["local", "network"].contains(first.lowercased()), let named = bracket() {
            task = named
        }
        let message = rest.trimmingCharacters(in: .whitespaces)
        return (task, message.isEmpty ? event : message)
    }

    static func parseLogDate(_ string: String) -> Date? {
        let formats = ["yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}

enum VersionComparator {
    /// Compares the numeric components: "24.0.2-1535" < "24.0.2-1541", "7.2.1-69057 Update 5" < "7.2.2-72806".
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = components(candidate)
        let b = components(installed)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
