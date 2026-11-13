import Foundation

/// Something worth a local notification. Platform-neutral, so other backends can reuse the detection.
public enum HealthEvent: Sendable, Hashable {
    public enum StorageProblem: Sendable, Hashable {
        case volume(name: String, status: HealthStatus)
        case volumeFull(name: String, usage: Double)
        case disk(name: String, status: HealthStatus)
    }

    case storageProblems([StorageProblem])
    /// Names of packages with an update that was not known at the last run.
    case packageUpdates([String])
    case systemUpdate(version: String)
    case containerFailed(name: String, exitCode: Int)
    /// A Hyper Backup task whose last run failed, or finished with skipped files (`partial`).
    case backupFailed(task: String, partial: Bool)
}

extension NotificationMatrix {
    public func allows(_ event: HealthEvent) -> Bool {
        switch event {
        case .storageProblems: storageProblems
        case .packageUpdates: packageUpdates
        case .systemUpdate: systemUpdates
        case .containerFailed: containerFailures
        // Not part of the matrix (its stored shape stays as it is); see `ServerProfile.allowsNotification`.
        case .backupFailed: true
        }
    }
}

extension ServerProfile {
    public func allowsNotification(for event: HealthEvent) -> Bool {
        switch event {
        case .backupFailed: notifyBackupFailures
        default: notifications.allows(event)
        }
    }
}

/// What the last run saw on one NAS. Comparing against it makes every problem report once.
public struct HealthState: Codable, Sendable, Hashable {
    /// Open storage problems, e.g. "volume/volume_1/degraded". Gone once fixed, so a relapse reports again.
    public var storageProblems: Set<String>
    /// "package-id@version"
    public var knownPackageUpdates: Set<String>
    public var knownSystemVersion: String?
    public var runningContainers: Set<String>
    /// Failed containers that were already reported; cleared when they run again.
    public var failedContainers: Set<String>
    /// "task-id@time of the last run" of backups that were already reported.
    public var failedBackups: Set<String>

    public init(
        storageProblems: Set<String> = [],
        knownPackageUpdates: Set<String> = [],
        knownSystemVersion: String? = nil,
        runningContainers: Set<String> = [],
        failedContainers: Set<String> = [],
        failedBackups: Set<String> = []
    ) {
        self.storageProblems = storageProblems
        self.knownPackageUpdates = knownPackageUpdates
        self.knownSystemVersion = knownSystemVersion
        self.runningContainers = runningContainers
        self.failedContainers = failedContainers
        self.failedBackups = failedBackups
    }
}

public enum HealthEventDetector {
    /// Volumes above this fill level count as a storage problem, unless the user chose another level.
    public static let defaultVolumeFullThreshold = 0.9

    /// Compares what was just read with the previous run. An input that is `nil` was not read
    /// (missing package, failed call) and leaves its part of the state untouched.
    ///
    /// The first run (`previous == nil`) only reports storage problems: updates and containers
    /// need a baseline first, otherwise enabling the refresh would report everything at once.
    public static func evaluate(
        previous: HealthState?,
        snapshot: SystemSnapshot?,
        updates: [UpdateItem]?,
        containers: [ContainerItem]?,
        backups: [BackupTask]? = nil,
        volumeFullThreshold: Double = defaultVolumeFullThreshold
    ) -> (state: HealthState, events: [HealthEvent]) {
        var state = previous ?? HealthState()
        var events: [HealthEvent] = []
        let isFirstRun = previous == nil

        if let snapshot {
            var open: [String: HealthEvent.StorageProblem] = [:]
            for volume in snapshot.volumes {
                if volume.status.isProblem {
                    open["volume/\(volume.id)/\(volume.status.rawValue)"] = .volume(name: volume.name, status: volume.status)
                }
                if volume.usage > volumeFullThreshold {
                    open["volume/\(volume.id)/full"] = .volumeFull(name: volume.name, usage: volume.usage)
                }
            }
            for disk in snapshot.disks where disk.status.isProblem {
                open["disk/\(disk.id)/\(disk.status.rawValue)"] = .disk(name: disk.name, status: disk.status)
            }
            let new = open.filter { !state.storageProblems.contains($0.key) }
            if !new.isEmpty {
                events.append(.storageProblems(new.sorted { $0.key < $1.key }.map(\.value)))
            }
            state.storageProblems = Set(open.keys)
        }

        if let updates {
            var packages: [String: String] = [:]
            var systemVersion: String?
            for update in updates {
                switch update.kind {
                case .package(let id): packages["\(id)@\(update.availableVersion)"] = update.name
                case .system: systemVersion = update.availableVersion
                }
            }
            let new = packages.filter { !state.knownPackageUpdates.contains($0.key) }
            if !new.isEmpty, !isFirstRun {
                events.append(.packageUpdates(new.values.sorted()))
            }
            state.knownPackageUpdates = Set(packages.keys)

            if let systemVersion, systemVersion != state.knownSystemVersion, !isFirstRun {
                events.append(.systemUpdate(version: systemVersion))
            }
            // Keep the version after it was installed: the same version never reports twice.
            if let systemVersion { state.knownSystemVersion = systemVersion }
        }

        if let containers {
            var failed = state.failedContainers.intersection(containers.map(\.name))
            for container in containers.sorted(by: { $0.name < $1.name }) {
                if container.status.isRunning {
                    failed.remove(container.name)
                } else if container.hasFailed, state.runningContainers.contains(container.name), !failed.contains(container.name) {
                    failed.insert(container.name)
                    events.append(.containerFailed(name: container.name, exitCode: container.exitCode ?? 0))
                }
            }
            state.failedContainers = failed
            state.runningContainers = Set(containers.filter(\.status.isRunning).map(\.name))
        }

        if let backups {
            var failed: Set<String> = []
            for task in backups.sorted(by: { $0.name < $1.name }) where task.needsAttention {
                let key = "\(task.id)@\(task.lastBackup.map { String(Int($0.timeIntervalSince1970)) } ?? "-")"
                failed.insert(key)
                if !state.failedBackups.contains(key) {
                    events.append(.backupFailed(task: task.name, partial: task.lastResult == .partial))
                }
            }
            state.failedBackups = failed
        }

        return (state, events)
    }
}
