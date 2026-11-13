import SwiftUI
import UIKit
import Domain

/// Copies a command to the clipboard and opens `host` in the terminal app (Settings → Terminal App).
/// An ssh:// link cannot carry a command, so the user pastes it after the login. The first tap explains
/// that in an alert; "Open, Don't Show Again" skips it from then on (per `hintKey`).
public struct ShellCommandButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let command: String
    let host: String
    let hintTitle: LocalizedStringKey
    let hintMessage: String
    let hintKey: String

    @Environment(\.openURL) private var openURL
    @State private var showHint = false

    public init(_ title: LocalizedStringKey, systemImage: String = "terminal.fill", command: String, host: String,
                hintTitle: LocalizedStringKey, hintMessage: String, hintKey: String) {
        self.title = title
        self.systemImage = systemImage
        self.command = command
        self.host = host
        self.hintTitle = hintTitle
        self.hintMessage = hintMessage
        self.hintKey = hintKey
    }

    public var body: some View {
        Button {
            UIPasteboard.general.string = command
            if UserDefaults.standard.bool(forKey: hintKey) { open() } else { showHint = true }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(verbatim: command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .alert(hintTitle, isPresented: $showHint) {
            Button("Open Terminal App") { open() }
            Button("Open, Don’t Show Again") {
                UserDefaults.standard.set(true, forKey: hintKey)
                open()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hintMessage)
        }
    }

    private func open() {
        if let url = SSHLink.url(host: host) { openURL(url) }
    }
}
