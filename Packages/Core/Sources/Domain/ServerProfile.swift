import Foundation

public typealias ServerID = UUID

public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case synology
    case proxmox

    /// Port the web interface listens on by default.
    public var defaultHTTPSPort: Int {
        switch self {
        case .synology: 5001
        case .proxmox: 8006
        }
    }

    public var supportsPlainHTTP: Bool { self == .synology }
}

/// How the app signs in. Synology: password (+ OTP). Proxmox: password (+ TOTP), API token or OpenID Connect.
public enum AuthMethod: Hashable, Codable, Sendable {
    /// Password of the account, kept in the Keychain. The Proxmox TOTP code is asked on each sign-in.
    case password
    /// Proxmox API token: the Keychain holds the secret, the token ID is the profile's `username` plus `!name`.
    case apiToken
    /// Proxmox OpenID Connect realm. The browser signs in; an API token created afterwards keeps the session
    /// alive without the browser (and makes background refresh possible).
    case openID(realm: String)

    /// Compact form for storage, e.g. "openID:keycloak".
    public var rawValue: String {
        switch self {
        case .password: "password"
        case .apiToken: "apiToken"
        case .openID(let realm): "openID:\(realm)"
        }
    }

    public init(rawValue: String) {
        if rawValue.hasPrefix("openID:") {
            self = .openID(realm: String(rawValue.dropFirst("openID:".count)))
        } else if rawValue == "apiToken" {
            self = .apiToken
        } else {
            self = .password
        }
    }

    public var isOpenID: Bool {
        if case .openID = self { return true }
        return false
    }
}

/// One way to reach a NAS (LAN, Tailscale, WireGuard …). A profile holds an ordered list.
public struct ServerAddress: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var host: String
    public var port: Int
    public var label: String
    /// Plain HTTP is only allowed for hosts in the local network or a VPN (see `isPrivateNetworkHost`).
    public var usesHTTPS: Bool

    public init(id: UUID = UUID(), host: String, port: Int = 5001, label: String = "", usesHTTPS: Bool = true) {
        self.id = id
        self.host = host
        self.port = port
        self.label = label
        self.usesHTTPS = usesHTTPS
    }

    private enum CodingKeys: String, CodingKey { case id, host, port, label, usesHTTPS }

    /// Profiles saved before HTTP existed have no `usesHTTPS` key: they stay HTTPS.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        usesHTTPS = try c.decodeIfPresent(Bool.self, forKey: .usesHTTPS) ?? true
    }

    /// Host as it must appear inside a URL (IPv6 literals need brackets).
    public var urlHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":"), !trimmed.hasPrefix("[") { return "[\(trimmed)]" }
        return trimmed
    }

    public static let defaultHTTPSPort = 5001
    public static let defaultHTTPPort = 5000

    /// HTTP may be used for this address.
    public var allowsPlainHTTP: Bool { Self.isPrivateNetworkHost(host) }

    /// Hosts that can only be reached inside the home network or through a VPN:
    /// private IPv4 ranges, Tailscale (100.64/10, *.ts.net), link-local, IPv6 ULA,
    /// `.local` and names without a dot. Public addresses never qualify.
    public static func isPrivateNetworkHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let bytes = octets.compactMap { Int($0) }
            guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }) else { return false }
            switch (bytes[0], bytes[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            // IPv6: unique local fc00::/7, link-local fe80::/10.
            guard let first = host.split(separator: ":").first, let value = Int(first, radix: 16) else { return false }
            return (value & 0xFE00) == 0xFC00 || (value & 0xFFC0) == 0xFE80
        }
        if host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        return !host.contains(".")
    }
}

/// Which background events may produce a local notification, per NAS.
public struct NotificationMatrix: Codable, Hashable, Sendable {
    public var storageProblems: Bool
    public var packageUpdates: Bool
    public var systemUpdates: Bool
    public var containerFailures: Bool

    public init(
        storageProblems: Bool = true,
        packageUpdates: Bool = true,
        systemUpdates: Bool = true,
        containerFailures: Bool = true
    ) {
        self.storageProblems = storageProblems
        self.packageUpdates = packageUpdates
        self.systemUpdates = systemUpdates
        self.containerFailures = containerFailures
    }
}

/// Persisted description of a NAS. Never contains secrets.
public struct ServerProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: ServerID
    public var name: String
    public var addresses: [ServerAddress]
    public var lastReachedAddressID: UUID?
    public var backend: BackendKind
    public var authMethod: AuthMethod
    /// Synology: account name. Proxmox: `user@realm`; with an API token `user@realm!tokenname`.
    public var username: String
    /// SHA-256 of the SubjectPublicKeyInfo (hex, lowercase). Pinned per NAS, not per address.
    public var pinnedSPKI: String?
    /// Set when the trusted certificate came from a public certificate authority: renewed certificates for this
    /// name are accepted without asking, also when the app connects by IP address (Let's Encrypt changes the key).
    public var trustedCertificateName: String?
    public var savesPassword: Bool
    public var backgroundRefresh: Bool
    public var notifications: NotificationMatrix
    /// Whether the saved credentials let the app sign in without the user (background refresh, re-login).
    /// An OpenID profile without an API token always needs the browser.
    public var canSignInUnattended: Bool {
        switch authMethod {
        case .password, .apiToken: savesPassword
        case .openID: savesPassword && hasAPIToken
        }
    }

    /// OpenID profiles that created an API token for unattended sign-in.
    public var hasAPIToken: Bool {
        authMethod == .apiToken || (authMethod.isOpenID && username.contains("!"))
    }

    /// Fifth notification type, added after the matrix: a failed Hyper Backup run.
    public var notifyBackupFailures: Bool
    public var sortOrder: Int
    public var colorName: String
    public var iconName: String
    /// MAC address (and broadcast) for waking the server; `nil` when not set up.
    public var wakeOnLAN: WakeOnLANConfig?

    public init(
        id: ServerID = UUID(),
        name: String,
        addresses: [ServerAddress],
        lastReachedAddressID: UUID? = nil,
        backend: BackendKind = .synology,
        authMethod: AuthMethod = .password,
        username: String,
        pinnedSPKI: String? = nil,
        trustedCertificateName: String? = nil,
        savesPassword: Bool = true,
        backgroundRefresh: Bool = false,
        notifications: NotificationMatrix = NotificationMatrix(),
        notifyBackupFailures: Bool = true,
        sortOrder: Int = 0,
        colorName: String = "blue",
        iconName: String = "externaldrive.connected.to.line.below",
        wakeOnLAN: WakeOnLANConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.lastReachedAddressID = lastReachedAddressID
        self.backend = backend
        self.authMethod = authMethod
        self.username = username
        self.pinnedSPKI = pinnedSPKI
        self.trustedCertificateName = trustedCertificateName
        self.savesPassword = savesPassword
        self.backgroundRefresh = backgroundRefresh
        self.notifications = notifications
        self.notifyBackupFailures = notifyBackupFailures
        self.sortOrder = sortOrder
        self.colorName = colorName
        self.iconName = iconName
        self.wakeOnLAN = wakeOnLAN
    }
}
