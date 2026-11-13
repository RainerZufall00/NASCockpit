import Foundation
import Domain

extension DSMMapping {
    static func containerStatus(_ status: String?) -> ContainerStatus {
        switch status?.lowercased() {
        case "running", "up": .running
        case "stopped": .stopped
        case "exited", "dead": .exited
        case "paused": .paused
        case "restarting": .restarting
        case "created": .created
        default: .unknown
        }
    }

    static func containers(_ list: ContainerListDTO, resources: ContainerResourceDTO?) -> [ContainerItem] {
        let usage = Dictionary((resources?.resources ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return list.containers
            .map { dto in
                let status = containerStatus(dto.status)
                return ContainerItem(
                    name: dto.name,
                    image: dto.image,
                    status: status,
                    exitCode: status.isRunning ? nil : dto.exitCode,
                    startedAt: dto.startedAt.flatMap(parseDockerDate),
                    cpuPercent: usage[dto.name]?.cpu,
                    memoryBytes: usage[dto.name]?.memory,
                    projectName: dto.project
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func projects(_ list: ProjectListDTO, containers: [ContainerItem]) -> [ComposeProject] {
        let byName = Dictionary(containers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return list.projects.map { dto in
            ComposeProject(
                id: dto.id,
                name: dto.name,
                status: projectStatus(dto.status, members: dto.containerNames.compactMap { byName[$0] }),
                containerNames: dto.containerNames,
                path: dto.path
            )
        }
    }

    /// Derived from the member containers when possible, DSM's own status otherwise.
    static func projectStatus(_ status: String?, members: [ContainerItem]) -> ProjectStatus {
        if !members.isEmpty {
            let running = members.filter(\.status.isRunning).count
            if running == members.count { return .running }
            if running == 0 { return .stopped }
            return .partial
        }
        switch status?.lowercased() {
        case "running": return .running
        case "stopped", "exited", "created": return .stopped
        case "partial", "partially_running": return .partial
        default: return .unknown
        }
    }

    static func containerLogs(_ dto: ContainerLogDTO) -> [ContainerLogLine] {
        dto.logs.enumerated().map { index, line in
            ContainerLogLine(id: index, date: line.created.flatMap(parseDockerDate), stream: line.stream, text: line.text)
        }
    }

    /// Docker uses RFC 3339 with up to nanoseconds ("2026-01-02T03:04:05.123456789Z").
    /// "0001-01-01T00:00:00Z" means "never started".
    static func parseDockerDate(_ string: String) -> Date? {
        var value = string
        if let dot = value.firstIndex(of: "."), let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            value.removeSubrange(dot..<zone)
        }
        guard let date = try? Date(value, strategy: .iso8601), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}
