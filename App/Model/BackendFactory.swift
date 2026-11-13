import AuthenticationServices
import Foundation
import UIKit
import Domain
import ProxmoxBackend
import SynologyBackend

/// The one place that knows which adapter serves which `BackendKind`.
enum BackendFactory {
    static func make(for profile: ServerProfile, credentials: any CredentialProvider, deviceName: String, interactive: Bool) -> any ServerBackend {
        switch profile.backend {
        case .synology:
            return SynologyBackend(profile: profile, credentials: credentials, deviceName: deviceName)
        case .proxmox:
            return ProxmoxBackend(profile: profile, credentials: credentials, deviceName: deviceName, openID: interactive ? OpenIDWebAuthorizer() : nil)
        }
    }
}

/// Runs the identity provider's sign-in in a system browser sheet (`ASWebAuthenticationSession`), so
/// passkeys and the browser's existing sessions work. Returns the `nascockpit://oidc?…` callback.
final class OpenIDWebAuthorizer: NSObject, OpenIDAuthorizer, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code == .canceledLogin {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error ?? CancellationError())
                    }
                }
                session.presentationContextProvider = self
                // Not ephemeral: the identity provider's existing session and passkeys stay usable.
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
