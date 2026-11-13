import Foundation

/// Opens the identity provider in a browser and returns the callback URL
/// (`nascockpit://oidc?code=…&state=…`). Implemented by the app with `ASWebAuthenticationSession`;
/// this module stays free of UI.
public protocol OpenIDAuthorizer: Sendable {
    /// Throws `CancellationError` when the user closes the browser.
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

public enum OpenIDRedirect {
    /// Registered in the app's Info.plist. The identity provider has to allow this redirect URI.
    public static let scheme = "nascockpit"
    public static let url = "nascockpit://oidc"
}
