import Foundation

public struct ServerCredentials: Sendable, Hashable {
    public var password: String
    public var deviceID: String?

    public init(password: String, deviceID: String? = nil) {
        self.password = password
        self.deviceID = deviceID
    }
}

/// Supplies credentials on demand. Implementations: Keychain (foreground / background copy)
/// and an in-memory store for "don't save password" and the add-server flow.
public protocol CredentialProvider: Sendable {
    /// `nil` means no password is available – the user has to sign in.
    func credentials(for server: ServerID) async throws -> ServerCredentials?
    func storeDeviceID(_ deviceID: String, for server: ServerID) async throws
}

public actor InMemoryCredentialProvider: CredentialProvider {
    private var storage: [ServerID: ServerCredentials] = [:]

    public init() {}

    public func set(_ credentials: ServerCredentials, for server: ServerID) {
        storage[server] = credentials
    }

    public func remove(_ server: ServerID) {
        storage[server] = nil
    }

    public func credentials(for server: ServerID) -> ServerCredentials? {
        storage[server]
    }

    public func storeDeviceID(_ deviceID: String, for server: ServerID) {
        storage[server]?.deviceID = deviceID
    }
}
