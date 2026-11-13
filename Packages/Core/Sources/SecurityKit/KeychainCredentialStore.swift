import Foundation
import LocalAuthentication
import Security
import Domain

/// Keychain storage for NAS credentials, addressed by server UUID (never by host name).
///
/// - Foreground items (password, device ID): `WhenUnlockedThisDeviceOnly` + `.userPresence`.
/// - Background copy (opt-in per NAS): `AfterFirstUnlockThisDeviceOnly`, no user presence,
///   so a `BGAppRefreshTask` can sign in while the device is locked.
///
/// Neither is included in backups or transferred to other devices.
public actor KeychainCredentialStore: CredentialProvider {
    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case accessControl
        case authenticationFailed
    }

    enum Item: String, CaseIterable {
        case password
        case deviceID = "device-id"
        case background
    }

    private struct BackgroundPayload: Codable {
        var password: String
        var deviceID: String?
    }

    private let service: String
    private let reason: String
    private var context: LAContext?
    private var authenticationTask: Task<Void, Error>?

    public init(
        service: String = "com.nascockpit.credentials",
        authenticationReason: String = String(localized: "Unlock the saved credentials of your NAS")
    ) {
        self.service = service
        self.reason = authenticationReason
    }

    // MARK: Authentication context

    /// Authenticates once (Face ID / passcode) so several NAS can be unlocked with a single prompt.
    public func authenticate() async throws {
        if context != nil { return }
        if let authenticationTask { return try await authenticationTask.value }
        let task = Task { try await self.performAuthentication() }
        authenticationTask = task
        defer { authenticationTask = nil }
        try await task.value
    }

    private func performAuthentication() async throws {
        let newContext = LAContext()
        newContext.localizedReason = reason
        let reason = self.reason
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            newContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? KeychainError.authenticationFailed)
                }
            }
        }
        context = newContext
    }

    /// Call when the app moves to the background.
    public func invalidateAuthentication() {
        context?.invalidate()
        context = nil
    }

    // MARK: CredentialProvider

    public func credentials(for server: ServerID) async throws -> ServerCredentials? {
        guard try exists(.password, for: server) else { return nil }
        try await authenticate()
        guard let password = try readProtected(.password, for: server) else { return nil }
        let deviceID = try readProtected(.deviceID, for: server)
        return ServerCredentials(
            password: String(decoding: password, as: UTF8.self),
            deviceID: deviceID.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    public func storeDeviceID(_ deviceID: String, for server: ServerID) async throws {
        try delete(.deviceID, for: server)
        try addProtected(Data(deviceID.utf8), item: .deviceID, for: server)
        if var payload = try readBackgroundPayload(for: server) {
            payload.deviceID = deviceID
            try writeBackgroundPayload(payload, for: server)
        }
    }

    // MARK: Management

    public func save(_ credentials: ServerCredentials, for server: ServerID, includeBackgroundCopy: Bool) throws {
        try deleteAll(for: server)
        try addProtected(Data(credentials.password.utf8), item: .password, for: server)
        if let deviceID = credentials.deviceID {
            try addProtected(Data(deviceID.utf8), item: .deviceID, for: server)
        }
        if includeBackgroundCopy {
            try writeBackgroundPayload(BackgroundPayload(password: credentials.password, deviceID: credentials.deviceID), for: server)
        }
    }

    /// Turning the background copy off deletes it immediately.
    public func setBackgroundCopy(enabled: Bool, for server: ServerID) async throws {
        guard enabled else {
            try delete(.background, for: server)
            return
        }
        guard let credentials = try await credentials(for: server) else { return }
        try writeBackgroundPayload(BackgroundPayload(password: credentials.password, deviceID: credentials.deviceID), for: server)
    }

    /// Readable while the device is locked (after first unlock). Only for background refresh.
    public func backgroundCredentials(for server: ServerID) throws -> ServerCredentials? {
        try readBackgroundPayload(for: server).map { ServerCredentials(password: $0.password, deviceID: $0.deviceID) }
    }

    public func hasBackgroundCopy(for server: ServerID) throws -> Bool {
        try exists(.background, for: server)
    }

    public func deleteAll(for server: ServerID) throws {
        for item in Item.allCases {
            try delete(item, for: server)
        }
    }

    /// Re-addresses this device's items of a merged duplicate profile to the surviving one.
    /// Only renames the accounts, never reads the secrets, so no Face ID. Keeps what the survivor already has.
    public func moveAll(from old: ServerID, to new: ServerID) {
        for item in Item.allCases {
            guard (try? exists(item, for: new)) == false else {
                try? delete(item, for: old)
                continue
            }
            var query = baseQuery(item, old)
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            let status = SecItemUpdate(query as CFDictionary, [kSecAttrAccount as String: account(item, new)] as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                // Could not move it: the user signs in once on the surviving profile.
                try? delete(item, for: old)
            }
        }
    }

    // MARK: Keychain primitives

    private func account(_ item: Item, _ server: ServerID) -> String {
        "\(server.uuidString).\(item.rawValue)"
    }

    private func baseQuery(_ item: Item, _ server: ServerID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(item, server),
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func exists(_ item: Item, for server: ServerID) throws -> Bool {
        var query = baseQuery(item, server)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Attributes are readable without user presence; this never shows a prompt.
        let failingContext = LAContext()
        failingContext.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = failingContext
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    private func addProtected(_ data: Data, item: Item, for server: ServerID) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw KeychainError.accessControl
        }
        var query = baseQuery(item, server)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func readProtected(_ item: Item, for server: ServerID) throws -> Data? {
        var query = baseQuery(item, server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed:
            invalidateAuthentication()
            throw KeychainError.authenticationFailed
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    private func writeBackgroundPayload(_ payload: BackgroundPayload, for server: ServerID) throws {
        try delete(.background, for: server)
        var query = baseQuery(.background, server)
        query[kSecValueData as String] = try JSONEncoder().encode(payload)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func readBackgroundPayload(for server: ServerID) throws -> BackgroundPayload? {
        var query = baseQuery(.background, server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(BackgroundPayload.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func delete(_ item: Item, for server: ServerID) throws {
        let status = SecItemDelete(baseQuery(item, server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Credential provider for background refresh: reads only the background copy, never prompts.
public struct BackgroundCredentialProvider: CredentialProvider {
    private let store: KeychainCredentialStore

    public init(store: KeychainCredentialStore) {
        self.store = store
    }

    public func credentials(for server: ServerID) async throws -> ServerCredentials? {
        try await store.backgroundCredentials(for: server)
    }

    public func storeDeviceID(_ deviceID: String, for server: ServerID) async throws {
        // The background path never performs an OTP login, so a new device ID is not expected here.
    }
}
