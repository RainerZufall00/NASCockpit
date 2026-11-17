// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    defaultLocalization: "en",
    platforms: [.iOS("26.0")],
    products: [
        // One umbrella product keeps the Xcode project simple. The module
        // boundaries below still enforce the layering from the architecture plan.
        .library(
            name: "AppModules",
            targets: [
                "Domain",
                "Networking",
                "SecurityKit",
                "Persistence",
                "SynologyBackend",
                "ProxmoxBackend",
                "DemoBackend",
                "DesignSystem",
                "DashboardFeature",
                "PackagesFeature",
                "UpdatesFeature",
                "LogsFeature",
                "ContainersFeature",
                "ControlPanelFeature",
                "FilesFeature",
                "BackupFeature",
                "SnapshotsFeature",
                "InboxFeature",
                "VirtualMachinesFeature",
                "SecurityAdvisorFeature",
            ]
        ),
        // What the widget extension needs: the status cache and the shared look. No networking, no Keychain.
        .library(name: "WidgetModules", targets: ["Domain", "Persistence", "DesignSystem"]),
    ],
    targets: [
        // Platform-neutral models and protocols. Knows nothing about DSM.
        .target(name: "Domain"),

        // Transport, address selection, TLS / SPKI pinning.
        .target(name: "Networking", dependencies: ["Domain"]),

        // Keychain, app lock, biometric confirmation.
        .target(name: "SecurityKit", dependencies: ["Domain"]),

        // SwiftData profiles, app-group status cache.
        .target(name: "Persistence", dependencies: ["Domain"]),

        // The only module that knows DSM.
        .target(name: "SynologyBackend", dependencies: ["Domain", "Networking"]),

        // The only module that knows Proxmox VE.
        .target(name: "ProxmoxBackend", dependencies: ["Domain", "Networking"]),

        // MockBackend for demo mode, previews and App Store screenshots.
        .target(name: "DemoBackend", dependencies: ["Domain"]),

        .target(name: "DesignSystem", dependencies: ["Domain"]),

        // Feature modules depend on Domain + DesignSystem only (DemoBackend for previews).
        .target(name: "DashboardFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "PackagesFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "UpdatesFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "LogsFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "ContainersFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "ControlPanelFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        .target(name: "FilesFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        // Reuses the log list for the Hyper Backup log.
        .target(name: "BackupFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend", "LogsFeature"]),
        .target(name: "SnapshotsFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        // The NAS's own notifications, across all NAS.
        .target(name: "InboxFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        // Proxmox: virtual machines and containers.
        .target(name: "VirtualMachinesFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),
        // DSM Security Advisor: results of the last scan (read-only).
        .target(name: "SecurityAdvisorFeature", dependencies: ["Domain", "DesignSystem", "DemoBackend"]),

        .testTarget(
            name: "NetworkingTests",
            dependencies: ["Networking", "Domain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SynologyBackendTests",
            dependencies: ["SynologyBackend", "Networking", "Domain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ProxmoxBackendTests",
            dependencies: ["ProxmoxBackend", "Networking", "Domain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DemoBackendTests",
            dependencies: ["DemoBackend", "Domain"]
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain"]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "Domain"]
        ),
    ]
)
