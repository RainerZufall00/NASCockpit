import Foundation
import Domain

/// Static description of one demo NAS.
public struct DemoServerSpec: Sendable {
    public let profile: ServerProfile
    public let model: String
    public let osVersion: String
    public let uptimeBase: TimeInterval
    public let cpuBase: Double
    public let memoryBase: Double
    public let memoryTotal: Int64
    public let volumes: [VolumeInfo]
    public let disks: [DiskInfo]
    public let packages: [PackageItem]
    public let systemUpdate: String?
    public let isOffline: Bool
    public let capabilities: Set<Capability>
    public var containers: [ContainerItem] = []
    public var projects: [ComposeProject] = []
    /// Proxmox demo host only.
    public var guests: [VirtualGuest] = []
}

public enum DemoData {
    private static let tb: Int64 = 1_000_000_000_000
    private static let gib: Int64 = 1_073_741_824

    public static let homeID = UUID(uuidString: "6C3E2D1A-0000-4000-8000-000000000001")!
    public static let officeID = UUID(uuidString: "6C3E2D1A-0000-4000-8000-000000000002")!
    public static let backupID = UUID(uuidString: "6C3E2D1A-0000-4000-8000-000000000003")!
    public static let proxmoxID = UUID(uuidString: "6C3E2D1A-0000-4000-8000-000000000004")!

    public static let servers: [DemoServerSpec] = [
        DemoServerSpec(
            profile: ServerProfile(
                id: homeID, name: "Home NAS",
                addresses: [ServerAddress(host: "nas.home.example", label: "LAN")],
                username: "nas-admin", sortOrder: 0, colorName: "blue"
            ),
            model: "DS923+",
            osVersion: "DSM 7.2.2-72806 Update 3",
            uptimeBase: 1_234_000,
            cpuBase: 0.12,
            memoryBase: 0.38,
            memoryTotal: 8 * gib,
            volumes: [
                VolumeInfo(id: "volume_1", name: "Volume 1", status: .normal, totalBytes: 11 * tb, usedBytes: 7_150_000_000_000, fileSystem: "btrfs"),
                VolumeInfo(id: "volume_2", name: "Volume 2", status: .normal, totalBytes: 2 * tb, usedBytes: 410_000_000_000, fileSystem: "btrfs"),
            ],
            disks: [
                DiskInfo(id: "sata1", name: "Drive 1", model: "HAT5300-4T", temperature: 34, status: .normal),
                DiskInfo(id: "sata2", name: "Drive 2", model: "HAT5300-4T", temperature: 35, status: .normal),
                DiskInfo(id: "sata3", name: "Drive 3", model: "HAT5300-4T", temperature: 36, status: .normal),
                DiskInfo(id: "sata4", name: "Drive 4", model: "HAT5300-4T", temperature: 34, status: .normal),
            ],
            packages: [
                PackageItem(id: "ContainerManager", name: "Container Manager", version: "24.0.2-1535", status: .running, availableVersion: "24.0.2-1541", summary: "Run containers on your NAS."),
                PackageItem(id: "HyperBackup", name: "Hyper Backup", version: "4.1.1-3733", status: .running, summary: "Back up data to local or remote targets."),
                PackageItem(id: "SynologyPhotos", name: "Synology Photos", version: "1.7.0-0794", status: .running, availableVersion: "1.7.1-0811", summary: "Organise and share photos."),
                PackageItem(id: "WebStation", name: "Web Station", version: "4.1.0-0380", status: .stopped, summary: "Host websites."),
                PackageItem(id: "TextEditor", name: "Text Editor", version: "1.2.0-0120", status: .running),
            ],
            systemUpdate: nil,
            isOffline: false,
            capabilities: [.dashboard, .packages, .systemUpdate, .logs, .containers, .files, .settings, .updateSettings, .users, .terminal, .power, .connections, .backup, .backupLogs, .snapshots, .replication, .notifications, .vms],
            containers: [
                ContainerItem(name: "homeassistant", image: "ghcr.io/home-assistant/home-assistant:stable", status: .running, startedAt: .now.addingTimeInterval(-86_400 * 6), cpuPercent: 3.2, memoryBytes: 612 * 1_048_576, projectName: "smarthome"),
                ContainerItem(name: "mosquitto", image: "eclipse-mosquitto:2", status: .running, startedAt: .now.addingTimeInterval(-86_400 * 6), cpuPercent: 0.1, memoryBytes: 9 * 1_048_576, projectName: "smarthome"),
                ContainerItem(name: "zigbee2mqtt", image: "koenkk/zigbee2mqtt:latest", status: .exited, exitCode: 1, projectName: "smarthome"),
                ContainerItem(name: "jellyfin", image: "jellyfin/jellyfin:10.10", status: .running, startedAt: .now.addingTimeInterval(-3_600 * 20), cpuPercent: 11.4, memoryBytes: 1_180 * 1_048_576),
                ContainerItem(name: "paperless", image: "ghcr.io/paperless-ngx/paperless-ngx:2", status: .stopped, exitCode: 0),
            ],
            projects: [
                ComposeProject(id: "smarthome", name: "smarthome", status: .partial, containerNames: ["homeassistant", "mosquitto", "zigbee2mqtt"], path: "/volume1/docker/smarthome"),
            ],
            guests: [
                VirtualGuest(id: "vmm-1", vmid: 1, name: "ubuntu-dev", node: "Home NAS", kind: .virtualMachine, status: .running, cpuLoad: 0.08, cores: 2, memoryBytes: 1_200 * 1_048_576, maxMemoryBytes: 4 * gib, uptime: 300_000, tags: ["Development box"]),
                VirtualGuest(id: "vmm-2", vmid: 2, name: "win11-office", node: "Home NAS", kind: .virtualMachine, status: .stopped, cores: 4, maxMemoryBytes: 8 * gib),
            ]
        ),
        DemoServerSpec(
            profile: ServerProfile(
                id: officeID, name: "Office NAS",
                addresses: [ServerAddress(host: "10.0.20.5", label: "Office VPN")],
                username: "it-admin", sortOrder: 1, colorName: "orange", iconName: "building.2"
            ),
            model: "DS1522+",
            osVersion: "DSM 7.2.1-69057 Update 5",
            uptimeBase: 4_020_000,
            cpuBase: 0.31,
            memoryBase: 0.62,
            memoryTotal: 16 * gib,
            volumes: [
                VolumeInfo(id: "volume_1", name: "Volume 1", status: .degraded, totalBytes: 32 * tb, usedBytes: 29_600_000_000_000, fileSystem: "btrfs"),
            ],
            disks: [
                DiskInfo(id: "sata1", name: "Drive 1", model: "HAT5310-8T", temperature: 39, status: .normal),
                DiskInfo(id: "sata2", name: "Drive 2", model: "HAT5310-8T", temperature: 41, status: .normal),
                DiskInfo(id: "sata3", name: "Drive 3", model: "HAT5310-8T", temperature: 40, status: .warning),
                DiskInfo(id: "sata4", name: "Drive 4", model: "HAT5310-8T", temperature: 40, status: .crashed),
                DiskInfo(id: "sata5", name: "Drive 5", model: "HAT5310-8T", temperature: 38, status: .normal),
            ],
            packages: [
                PackageItem(id: "ActiveBackup", name: "Active Backup for Business", version: "2.7.0-13234", status: .running, availableVersion: "2.7.1-13241"),
                PackageItem(id: "SynologyDrive", name: "Synology Drive Server", version: "3.5.0-26085", status: .running, availableVersion: "3.5.1-26102"),
                PackageItem(id: "ContainerManager", name: "Container Manager", version: "24.0.2-1535", status: .running, availableVersion: "24.0.2-1541"),
                PackageItem(id: "LogCenter", name: "Log Center", version: "1.3.0-0434", status: .running),
            ],
            systemUpdate: "DSM 7.2.2-72806 Update 3",
            isOffline: false,
            capabilities: [.dashboard, .packages, .systemUpdate, .logs, .containers, .files, .settings, .updateSettings, .users, .terminal, .power, .connections, .backup, .backupLogs, .snapshots, .replication, .notifications],
            containers: [
                ContainerItem(name: "gitea", image: "gitea/gitea:1.22", status: .running, startedAt: .now.addingTimeInterval(-86_400 * 30), cpuPercent: 1.8, memoryBytes: 240 * 1_048_576, projectName: "devtools"),
                ContainerItem(name: "gitea-db", image: "postgres:16", status: .running, startedAt: .now.addingTimeInterval(-86_400 * 30), cpuPercent: 0.9, memoryBytes: 180 * 1_048_576, projectName: "devtools"),
                ContainerItem(name: "uptime-kuma", image: "louislam/uptime-kuma:1", status: .running, startedAt: .now.addingTimeInterval(-86_400 * 2), cpuPercent: 2.1, memoryBytes: 140 * 1_048_576),
            ],
            projects: [
                ComposeProject(id: "devtools", name: "devtools", status: .running, containerNames: ["gitea", "gitea-db"], path: "/volume1/docker/devtools"),
            ]
        ),
        DemoServerSpec(
            profile: ServerProfile(
                id: backupID, name: "Backup NAS",
                addresses: [ServerAddress(host: "backup.example", label: "Tailscale")],
                username: "backup-admin", sortOrder: 2, colorName: "green", iconName: "archivebox",
                wakeOnLAN: WakeOnLANConfig(mac: MACAddress("00:11:32:5A:7B:12")!, broadcast: "192.168.1.255")
            ),
            model: "DS224+",
            osVersion: "DSM 7.2.2-72806",
            uptimeBase: 0,
            cpuBase: 0.05,
            memoryBase: 0.2,
            memoryTotal: 2 * gib,
            volumes: [],
            disks: [],
            packages: [],
            systemUpdate: nil,
            isOffline: true,
            capabilities: [.dashboard, .packages, .logs]
        ),
        DemoServerSpec(
            profile: ServerProfile(
                id: proxmoxID, name: "Proxmox Lab",
                addresses: [ServerAddress(host: "pve.home.example", port: 8006, label: "LAN")],
                backend: .proxmox, authMethod: .apiToken, username: "root@pam!nascockpit",
                sortOrder: 3, colorName: "orange", iconName: "server.rack"
            ),
            model: "pve · Intel Core i5-1235U (12 threads)",
            osVersion: "Proxmox VE 8.3.2",
            uptimeBase: 2_345_000,
            cpuBase: 0.18,
            memoryBase: 0.71,
            memoryTotal: 64 * gib,
            volumes: [
                VolumeInfo(id: "rootfs", name: "Root file system", status: .normal, totalBytes: 100 * 1_000_000_000, usedBytes: 23 * 1_000_000_000),
                VolumeInfo(id: "local-zfs", name: "local-zfs", status: .normal, totalBytes: 1_800_000_000_000, usedBytes: 640_000_000_000, fileSystem: "zfspool"),
                VolumeInfo(id: "nas-backup", name: "nas-backup", status: .normal, totalBytes: 4 * tb, usedBytes: 1_300_000_000_000, fileSystem: "nfs"),
            ],
            disks: [
                DiskInfo(id: "/dev/nvme0n1", name: "nvme0n1 (NVME)", model: "Samsung SSD 980 PRO 2TB", status: .normal),
                DiskInfo(id: "/dev/sda", name: "sda (SSD)", model: "Samsung SSD 870 EVO 1TB", status: .normal),
            ],
            packages: [
                PackageItem(id: "pve-manager", name: "pve-manager", version: "8.3.2", status: .running, availableVersion: "8.3.3", summary: "Proxmox Virtual Environment Management Tools"),
                PackageItem(id: "proxmox-kernel-6.8", name: "proxmox-kernel-6.8", version: "6.8.12-5", status: .running, availableVersion: "6.8.12-8", summary: "Proxmox kernel"),
                PackageItem(id: "qemu-server", name: "qemu-server", version: "8.3.3", status: .running, availableVersion: "8.3.4", summary: "QEMU server tools"),
                PackageItem(id: "openssl", name: "openssl", version: "3.0.15-1~deb12u1", status: .running, availableVersion: "3.0.16-1~deb12u1", summary: "Secure Sockets Layer toolkit"),
            ],
            systemUpdate: nil,
            isOffline: false,
            capabilities: [.dashboard, .vms, .guestSnapshots, .backup, .backupLogs, .logs, .settings, .power],
            guests: [
                VirtualGuest(id: "qemu/100", vmid: 100, name: "homeassistant", node: "pve", kind: .virtualMachine, status: .running, cpuLoad: 0.06, cores: 2, memoryBytes: 1_900 * 1_048_576, maxMemoryBytes: 4 * gib, maxDiskBytes: 32 * 1_000_000_000, uptime: 1_900_000, tags: ["smarthome"]),
                VirtualGuest(id: "qemu/101", vmid: 101, name: "win11-test", node: "pve", kind: .virtualMachine, status: .stopped, cores: 4, maxMemoryBytes: 8 * gib, maxDiskBytes: 120 * 1_000_000_000),
                VirtualGuest(id: "qemu/102", vmid: 102, name: "truenas", node: "pve", kind: .virtualMachine, status: .running, cpuLoad: 0.12, cores: 4, memoryBytes: 14 * gib, maxMemoryBytes: 16 * gib, maxDiskBytes: 64 * 1_000_000_000, uptime: 2_300_000, tags: ["storage"]),
                VirtualGuest(id: "qemu/900", vmid: 900, name: "debian-12-template", node: "pve", kind: .virtualMachine, status: .stopped, cores: 1, maxMemoryBytes: 2 * gib, isTemplate: true),
                VirtualGuest(id: "lxc/200", vmid: 200, name: "pihole", node: "pve", kind: .container, status: .running, cpuLoad: 0.01, cores: 1, memoryBytes: 180 * 1_048_576, maxMemoryBytes: 512 * 1_048_576, maxDiskBytes: 8 * 1_000_000_000, uptime: 2_340_000, tags: ["network"]),
                VirtualGuest(id: "lxc/201", vmid: 201, name: "nginx-proxy", node: "pve", kind: .container, status: .running, cpuLoad: 0.02, cores: 2, memoryBytes: 310 * 1_048_576, maxMemoryBytes: 1 * gib, maxDiskBytes: 8 * 1_000_000_000, uptime: 2_340_000, tags: ["network"]),
                VirtualGuest(id: "lxc/202", vmid: 202, name: "paperless", node: "pve", kind: .container, status: .stopped, cores: 2, maxMemoryBytes: 2 * gib, maxDiskBytes: 40 * 1_000_000_000),
            ]
        ),
    ]

    public static var profiles: [ServerProfile] { servers.map(\.profile) }

    public static func spec(for id: ServerID) -> DemoServerSpec? {
        servers.first { $0.profile.id == id }
    }

    static let containerLogMessages: [String] = [
        "INFO  Starting service",
        "INFO  Listening on 0.0.0.0:8080",
        "DEBUG Health check ok",
        "INFO  GET /api/status 200 3ms",
        "WARN  Slow request: GET /api/library 1240ms",
        "INFO  Scheduled job \"cleanup\" finished",
        "INFO  Connected to database",
        "DEBUG Cache hit ratio 0.93",
    ]

    static let logMessages: [(LogLevel, String, String?, String)] = [
        (.info, "Connection", "nas-admin", "User [nas-admin] from [192.0.2.10] signed in to [DSM] successfully."),
        (.info, "System", "SYSTEM", "Scheduled task [Weekly S.M.A.R.T. test] started."),
        (.info, "System", "SYSTEM", "Package [Container Manager] has been started."),
        (.warning, "System", "SYSTEM", "Volume 1 usage is above 85 %."),
        (.info, "Connection", "nas-admin", "User [nas-admin] signed out from [DSM]."),
        (.error, "System", "SYSTEM", "Drive 4 in the storage pool reported a S.M.A.R.T. error."),
        (.info, "System", "SYSTEM", "Hyper Backup task [Offsite] finished successfully."),
        (.warning, "Connection", nil, "Failed sign-in attempt from [198.51.100.7]."),
        (.info, "System", "SYSTEM", "System successfully completed the data scrubbing."),
        (.info, "System", "SYSTEM", "Package [Synology Photos] update is available."),
    ]

    // MARK: Control Panel and File Station

    static let users: [NASUser] = [
        NASUser(name: "nas-admin", fullName: "Administrator (App)", email: "admin@home.example", isDisabled: false),
        NASUser(name: "admin", fullName: "System default user", isDisabled: true),
        NASUser(name: "anna", fullName: "Anna", email: "anna@home.example", isDisabled: false),
        NASUser(name: "ben", fullName: "Ben", isDisabled: false),
        NASUser(name: "guest", fullName: "Guest", isDisabled: true),
        NASUser(name: "scanner", fullName: "Office scanner (SMB)", isDisabled: false),
    ]

    static func connections(now: Date = .now) -> [ActiveConnection] {
        [
            ActiveConnection(user: "nas-admin", address: "100.84.12.7", kind: "HTTP/HTTPS", since: now.addingTimeInterval(-60)),
            ActiveConnection(user: "anna", address: "192.168.1.23", kind: "SMB", since: now.addingTimeInterval(-3 * 3600)),
            ActiveConnection(user: "ben", address: "192.168.1.41", kind: "Synology Drive", since: now.addingTimeInterval(-26 * 3600)),
            ActiveConnection(user: "scanner", address: "192.168.1.90", kind: "SMB", since: now.addingTimeInterval(-15 * 60)),
        ]
    }

    static func notifications(for server: ServerID, now: Date = .now) -> [NASNotification] {
        func detail(_ label: String, _ value: String) -> NASNotification.Detail { .init(label: label, value: value) }
        if server == backupID {
            return [
                NASNotification(id: "b2", date: now.addingTimeInterval(-5 * 3600), level: .info, title: "Backup finished",
                                message: "Archive · 1 hour 12 minutes", details: [detail("Task type", "Local backup")]),
                NASNotification(id: "b1", date: now.addingTimeInterval(-3 * 86_400), level: .warning, title: "Drive reallocated sectors",
                                message: "Drive 2", details: []),
            ]
        }
        if server == officeID {
            return [
                NASNotification(id: "o3", date: now.addingTimeInterval(-3 * 3600), level: .warning, title: "Volume is running out of space",
                                message: "Volume 1 · 92 %", details: []),
                NASNotification(id: "o2", date: now.addingTimeInterval(-9 * 3600), level: .info, title: "Backup integrity check passed",
                                message: "Projects · 7 minutes 30 seconds", details: [detail("Task type", "Network backup")]),
                NASNotification(id: "o1", date: now.addingTimeInterval(-2 * 86_400), level: .error, title: "Error in the system log",
                                message: "admin: Failed to update package [Node.js v22].", details: []),
            ]
        }
        return [
            NASNotification(id: "4", date: now.addingTimeInterval(-40 * 60), level: .info, title: "Backup finished",
                            message: "Offsite (C2) · 39 minutes",
                            details: [detail("Destination path", "offsite.hbk"), detail("Task type", "Cloud backup")]),
            NASNotification(id: "3", date: now.addingTimeInterval(-26 * 3600), level: .error, title: "Backup failed",
                            message: "Docker configs · 4 minutes 32 seconds",
                            details: [detail("Destination path", "docker.hbk"), detail("Task type", "Network backup")]),
            NASNotification(id: "2", date: now.addingTimeInterval(-26 * 3600 - 40), level: .error, title: "Error in the system log",
                            message: "SYSTEM: [Network][Docker configs] Exception occurred while backing up data. (Network connection timed out.)",
                            details: []),
            NASNotification(id: "1", date: now.addingTimeInterval(-4 * 86_400), level: .error, title: "Container stopped unexpectedly",
                            message: "paperless-web", details: []),
        ]
    }

    static func backupTasks(now: Date = .now) -> [BackupTask] {
        let calendar = Calendar.current
        let tonight = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: now.addingTimeInterval(86_400)) ?? now
        return [
            BackupTask(id: "1", name: "Offsite (C2)", destination: .cloud("Synology C2"), lastResult: .success,
                       lastBackup: now.addingTimeInterval(-21 * 3600), nextBackup: tonight),
            // The USB drive is unplugged: shows "Destination offline" and the start fails.
            BackupTask(id: "2", name: "Photos to USB", destination: .local, lastResult: .partial,
                       lastBackup: now.addingTimeInterval(-2 * 86_400), nextBackup: tonight.addingTimeInterval(2 * 3600),
                       targetOnline: false),
            BackupTask(id: "3", name: "Docker configs", destination: .remoteNAS, lastResult: .failed,
                       lastBackup: now.addingTimeInterval(-26 * 3600), nextBackup: tonight.addingTimeInterval(3600)),
            BackupTask(id: "4", name: "Documents", destination: .remoteNAS, activity: .running(progress: 0.42), lastResult: .success,
                       lastBackup: now.addingTimeInterval(-6 * 86_400), nextBackup: nil),
        ]
    }

    /// Snapshots of the demo Proxmox guests, by guest ID.
    static func guestSnapshots(now: Date = .now) -> [String: [GuestSnapshot]] {
        [
            "qemu/100": [
                GuestSnapshot(name: "before_update_2026_10", description: "Home Assistant 2026.10 before the update",
                              date: now.addingTimeInterval(-26 * 86_400), includesMemory: true),
                GuestSnapshot(name: "clean_install", description: "Fresh install", date: now.addingTimeInterval(-120 * 86_400)),
            ],
            "lxc/200": [
                GuestSnapshot(name: "pihole_v6", description: "Before Pi-hole v6", date: now.addingTimeInterval(-9 * 86_400)),
            ],
        ]
    }

    /// vzdump jobs of the demo Proxmox host.
    static func proxmoxBackupTasks(now: Date = .now) -> [BackupTask] {
        let calendar = Calendar.current
        let tonight = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: now.addingTimeInterval(86_400)) ?? now
        return [
            BackupTask(id: "backup-daily", name: "Daily to NAS", destination: .other("nas-backup"), lastResult: .success,
                       lastBackup: now.addingTimeInterval(-20 * 3600), nextBackup: tonight),
            BackupTask(id: "backup-weekly-pbs", name: "Weekly to PBS", destination: .other("pbs-offsite"), lastResult: .failed,
                       lastBackup: now.addingTimeInterval(-3 * 86_400), nextBackup: tonight.addingTimeInterval(4 * 86_400)),
        ]
    }

    static func shareSnapshots(now: Date = .now) -> [ShareSnapshots] {
        let calendar = Calendar.current
        let today3am = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: now) ?? now
        let lastScheduled = today3am <= now ? today3am : today3am.addingTimeInterval(-86_400)
        func name(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy.MM.dd-HH.mm.ss"
            let hours = TimeZone.current.secondsFromGMT(for: date) / 3600
            return String(format: "GMT%+03d-", hours) + formatter.string(from: date)
        }
        func daily(_ count: Int, hourOffset: Double = 0) -> [SnapshotItem] {
            (0..<count).map { day in
                let date = lastScheduled.addingTimeInterval(-Double(day) * 86_400 + hourOffset * 3_600)
                return SnapshotItem(id: name(date), date: date, isScheduled: true)
            }
        }
        let manual = now.addingTimeInterval(-5 * 86_400 - 7 * 3_600)
        return [
            ShareSnapshots(share: "docker", snapshots: daily(7, hourOffset: 1)
                + [SnapshotItem(id: name(manual), date: manual, description: "Before Home Assistant 2026.11 update", isLocked: true)]),
            ShareSnapshots(share: "home", snapshots: daily(30)),
            ShareSnapshots(share: "media", snapshots: []),
            ShareSnapshots(share: "photo", snapshots: daily(14, hourOffset: 0.5)),
        ]
    }

    static func replicationPlans(now: Date = .now) -> [ReplicationPlan] {
        let tonight = Calendar.current.date(bySettingHour: 1, minute: 0, second: 0, of: now.addingTimeInterval(86_400)) ?? now
        return [
            ReplicationPlan(id: "plan-photo", name: "photo", partner: "office-nas", lastSync: now.addingTimeInterval(-20 * 3_600),
                            lastSyncSucceeded: true, nextSync: tonight),
            ReplicationPlan(id: "plan-docker", name: "docker", partner: "backup-nas", lastSync: now.addingTimeInterval(-44 * 3_600),
                            lastSyncSucceeded: false, nextSync: tonight, failedSyncCount: 2),
            ReplicationPlan(id: "plan-home", name: "home", partner: "office-nas", isSyncing: true, progress: 0.63,
                            lastSync: now.addingTimeInterval(-2 * 86_400), lastSyncSucceeded: true, nextSync: nil),
        ]
    }

    /// Folder tree: path → children. Files carry a size.
    static func fileTree(now: Date = .now) -> [String: [FileItem]] {
        func folder(_ path: String, days: Double) -> FileItem {
            FileItem(path: path, name: String(path.split(separator: "/").last!), isDirectory: true, modified: now.addingTimeInterval(-days * 86_400))
        }
        func file(_ path: String, mb: Double, days: Double) -> FileItem {
            FileItem(path: path, name: String(path.split(separator: "/").last!), isDirectory: false, size: Int64(mb * 1_000_000), modified: now.addingTimeInterval(-days * 86_400))
        }
        return [
            "/": [folder("/docker", days: 2), folder("/home", days: 1), folder("/homes", days: 30), folder("/media", days: 4), folder("/photo", days: 0.5)],
            "/docker": [folder("/docker/homeassistant", days: 2), folder("/docker/jellyfin", days: 6), folder("/docker/paperless", days: 9)],
            "/docker/homeassistant": [file("/docker/homeassistant/configuration.yaml", mb: 0.01, days: 2), file("/docker/homeassistant/home-assistant.log", mb: 4.2, days: 0.1)],
            "/docker/jellyfin": [folder("/docker/jellyfin/config", days: 6), folder("/docker/jellyfin/cache", days: 1)],
            "/docker/paperless": [folder("/docker/paperless/consume", days: 9), folder("/docker/paperless/export", days: 20)],
            "/home": [folder("/home/Documents", days: 3), folder("/home/Archive", days: 40), file("/home/Notes.txt", mb: 0.02, days: 1)],
            "/home/Documents": [folder("/home/Documents/Taxes 2025", days: 12), folder("/home/Documents/Insurance", days: 80), file("/home/Documents/Lease.pdf", mb: 2.4, days: 200)],
            "/home/Archive": [folder("/home/Archive/2023", days: 400), folder("/home/Archive/2024", days: 40)],
            "/homes": [folder("/homes/anna", days: 2), folder("/homes/ben", days: 5)],
            "/media": [folder("/media/Movies", days: 4), folder("/media/Series", days: 8), folder("/media/Music", days: 60)],
            "/photo": [folder("/photo/2024", days: 300), folder("/photo/2025", days: 20), folder("/photo/Holiday Italy", days: 90), file("/photo/cover.jpg", mb: 3.1, days: 90)],
            "/photo/2025": [folder("/photo/2025/January", days: 300), folder("/photo/2025/Summer", days: 100), file("/photo/2025/IMG_0042.HEIC", mb: 2.9, days: 20)],
        ]
    }
}
