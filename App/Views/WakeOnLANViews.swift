import SwiftUI
import Domain

/// "Wake Up" when a MAC address is set, otherwise "Set Up Wake-on-LAN…".
struct WakeButton: View {
    let manager: ConnectionManager
    let profile: ServerProfile
    @State private var showSetup = false

    var body: some View {
        Group {
            if profile.wakeOnLAN != nil {
                Button("Wake Up", systemImage: "power") { Task { await manager.wake(profile.id) } }
                    .disabled(manager.runtime[profile.id]?.wakingSince != nil)
            } else {
                Button("Wake-on-LAN…", systemImage: "power") { showSetup = true }
            }
        }
        .sheet(isPresented: $showSetup) {
            WakeOnLANSetupView(manager: manager, profile: profile)
        }
    }
}

/// Progress after the magic packet was sent, or why it failed.
struct WakeStatus: View {
    let manager: ConnectionManager
    let profile: ServerProfile

    var body: some View {
        let runtime = manager.runtime[profile.id]
        if let since = runtime?.wakingSince {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake-up sent. Waiting for \(profile.name) to start…")
                    Text("Since \(since, format: .relative(presentation: .named)). Starting can take a few minutes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { manager.cancelWake(profile.id) }
                    .buttonStyle(.borderless)
            }
            .font(.footnote)
            if runtime?.wakeBroadcastBlocked == true {
                Label("iOS blocked the broadcast, so the packet only went directly to the server's address. That often does not reach a server that has been off for a while.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let error = runtime?.wakeError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}

/// Enter or change the MAC address used to wake the server.
struct WakeOnLANSetupView: View {
    let manager: ConnectionManager
    let profile: ServerProfile
    @Environment(\.dismiss) private var dismiss
    @State private var mac = ""
    @State private var broadcast = ""

    private var parsedMAC: MACAddress? { MACAddress(mac) }
    private var broadcastIsValid: Bool {
        broadcast.isEmpty || WakeOnLAN.broadcast(address: broadcast, netmask: "255.255.255.255") != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("00:11:32:AB:CD:EF", text: $mac)
                        .monospaced()
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                } header: {
                    Text("MAC Address")
                } footer: {
                    if !mac.isEmpty, parsedMAC == nil {
                        Text("Not a valid MAC address: 12 hexadecimal digits, e.g. 00:11:32:AB:CD:EF.")
                            .foregroundStyle(.red)
                    } else {
                        Text(LocalizedStringKey(macHint))
                    }
                }
                Section {
                    TextField("192.168.1.255", text: $broadcast)
                        .monospaced()
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Broadcast Address (Optional)")
                } footer: {
                    if !broadcastIsValid {
                        Text("Not a valid IPv4 address.").foregroundStyle(.red)
                    } else {
                        Text("Leave empty to use the server's LAN address with .255 and 255.255.255.255.")
                    }
                }
                Section {
                    Text(LocalizedStringKey(setupHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("On the Server")
                } footer: {
                    Text("The iPhone must be in the same network as the server. Over a VPN the packet does not reach a sleeping server.")
                }
                if profile.wakeOnLAN != nil {
                    Section {
                        Button("Remove Wake-on-LAN", role: .destructive) {
                            manager.setWakeOnLAN(profile.id, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Wake-on-LAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsedMAC else { return }
                        manager.setWakeOnLAN(profile.id, WakeOnLANConfig(mac: parsedMAC, broadcast: broadcast.isEmpty ? nil : broadcast))
                        dismiss()
                    }
                    .disabled(parsedMAC == nil || !broadcastIsValid)
                }
            }
            .onAppear {
                mac = profile.wakeOnLAN?.mac.description ?? ""
                broadcast = profile.wakeOnLAN?.broadcast ?? ""
            }
        }
    }

    private var macHint: String {
        switch profile.backend {
        case .synology:
            String(localized: "Filled in automatically once the app has connected. DSM shows it under Control Panel → Network → Network Interface.")
        case .proxmox:
            String(localized: "On the host: `ip link` shows it as link/ether of the network port (e.g. eno1 or enp1s0), not of a bridge.")
        }
    }

    private var setupHint: String {
        switch profile.backend {
        case .synology:
            String(localized: "Turn on \"Enable WOL on LAN 1\" under Control Panel → Hardware & Power → General. Wake-on-LAN works after a shutdown, not after a power loss.")
        case .proxmox:
            String(localized: "Enable Wake-on-LAN in the BIOS, and on the host run `ethtool -s eno1 wol g` (with your port name). To keep it after a reboot, add `post-up ethtool -s eno1 wol g` to the port in /etc/network/interfaces.")
        }
    }
}
