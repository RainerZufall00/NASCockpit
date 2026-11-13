// Turns the raw simulator shots into App Store images: headline, subline, device frame and background – per language
// (de-DE, en-US) for iPhone 6.9", iPhone 6.3", iPad 13" (landscape) and both iPhone Duo displays. Plus the
// "Creative Assets" for App Store Connect (Creative/): product page header (21:9) and search results image (3:2).
// Run from the repository root: swift AppStore/Tools/compose-screenshots.swift
// The raw shots come from AppStore/Tools/capture-screenshots.sh and capture-duo-screenshots.sh (AppStore/Screenshots/raw).
// The app UI is English only, so both languages use the same raw shots; only the captions differ.
// Missing raw shots are skipped with a warning (for example the Duo before it has been captured).

import AppKit
import SwiftUI

let raw = URL(fileURLWithPath: "AppStore/Screenshots/raw")
let output = URL(fileURLWithPath: "AppStore/Screenshots")

// MARK: - Brand (colours of the app icon)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Brand {
    static let navy = Color(hex: 0x1B2744)
    static let navyDeep = Color(hex: 0x080D1A)
    static let ink = Color(hex: 0x0B1A3A)
    static let blue = Color(hex: 0x1F5BD8)
    static let blueLight = Color(hex: 0x5A98FF)
    static let orange = Color(hex: 0xFFB340)
    static let green = Color(hex: 0x5BF08A)
    static let mist = Color(hex: 0xDCE7F8)
}

enum Theme { case light, dark }

// MARK: - Devices

struct Device {
    let folder: String
    let canvas: CGSize
    let screenWidth: CGFloat
    let cornerRadius: CGFloat
    let bezel: CGFloat
    let headlineSize: CGFloat
    let sublineSize: CGFloat
    let textTop: CGFloat
    let textWidth: CGFloat

    /// iPhone 6.9" (1320 × 2868).
    static let iPhone = Device(folder: "iPhone-6.9", canvas: CGSize(width: 1320, height: 2868), screenWidth: 1030,
                               cornerRadius: 150, bezel: 24, headlineSize: 124, sublineSize: 50, textTop: 190, textWidth: 1180)
    /// iPhone 6.1"/6.3" (1206 × 2622) – same layout, scaled down; nearly the same aspect ratio.
    static let iPhoneCompact = iPhone.scaled(folder: "iPhone-6.3", to: CGSize(width: 1206, height: 2622))
    /// iPad 13" landscape (2752 × 2064) – also used by the App Store for all smaller iPads.
    static let iPad = Device(folder: "iPad-13", canvas: CGSize(width: 2752, height: 2064), screenWidth: 2240,
                             cornerRadius: 50, bezel: 30, headlineSize: 118, sublineSize: 52, textTop: 120, textWidth: 2400)
    /// iPhone Duo, outer display (1398 × 2034).
    static let duoOuter = Device(folder: "iPhone-Duo-outer", canvas: CGSize(width: 1398, height: 2034), screenWidth: 1110,
                                 cornerRadius: 96, bezel: 22, headlineSize: 100, sublineSize: 42, textTop: 120, textWidth: 1260)
    /// iPhone Duo, inner display (2007 × 2853).
    static let duoInner = Device(folder: "iPhone-Duo-inner", canvas: CGSize(width: 2007, height: 2853), screenWidth: 1580,
                                 cornerRadius: 96, bezel: 34, headlineSize: 128, sublineSize: 52, textTop: 180, textWidth: 1760)

    func scaled(folder: String, to canvas: CGSize) -> Device {
        let f = canvas.width / self.canvas.width
        return Device(folder: folder, canvas: canvas, screenWidth: screenWidth * f, cornerRadius: cornerRadius * f,
                      bezel: bezel * f, headlineSize: headlineSize * f, sublineSize: sublineSize * f,
                      textTop: textTop * f, textWidth: textWidth * f)
    }
}

// MARK: - Layout

struct Shot {
    let raw: String
    let output: String
    let headline: String
    let subline: String
    let theme: Theme
}

struct Background: View {
    let theme: Theme
    let size: CGSize

    var body: some View {
        ZStack {
            if theme == .dark {
                LinearGradient(colors: [Brand.navy, Brand.navyDeep], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [.white, Brand.mist], startPoint: .top, endPoint: .bottom)
            }
            // Soft glows in the icon colours, cut off at the edges.
            Circle()
                .fill(Brand.blueLight.opacity(theme == .dark ? 0.22 : 0.20))
                .frame(width: size.width * 0.6)
                .blur(radius: size.width * 0.06)
                .offset(x: size.width * 0.42, y: -size.height * 0.36)
            Circle()
                .fill(Brand.orange.opacity(theme == .dark ? 0.14 : 0.16))
                .frame(width: size.width * 0.34)
                .blur(radius: size.width * 0.05)
                .offset(x: -size.width * 0.46, y: -size.height * 0.18)
            Circle()
                .fill(Brand.green.opacity(theme == .dark ? 0.08 : 0.10))
                .frame(width: size.width * 0.7)
                .blur(radius: size.width * 0.08)
                .offset(x: -size.width * 0.4, y: size.height * 0.42)
        }
    }
}

struct Poster: View {
    let device: Device
    let shot: Shot
    let screenshot: NSImage

    var body: some View {
        let isDark = shot.theme == .dark
        ZStack(alignment: .top) {
            Background(theme: shot.theme, size: device.canvas)
            // The device follows the text, whether the headline has one line or two.
            VStack(spacing: device.sublineSize * 1.5) {
                VStack(spacing: device.sublineSize * 0.5) {
                    Text(shot.headline)
                        .font(.system(size: device.headlineSize, weight: .heavy))
                        .tracking(-device.headlineSize * 0.015)
                        .foregroundStyle(isDark ? .white : Brand.ink)
                        .lineSpacing(-device.headlineSize * 0.08)
                    Text(shot.subline)
                        .font(.system(size: device.sublineSize, weight: .medium))
                        .foregroundStyle(isDark ? Brand.orange : Brand.blue)
                        .lineSpacing(device.sublineSize * 0.12)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: device.textWidth)

                FramedScreen(screenshot: screenshot, width: device.screenWidth, cornerRadius: device.cornerRadius, bezel: device.bezel)
            }
            .padding(.top, device.textTop)
        }
        .frame(width: device.canvas.width, height: device.canvas.height, alignment: .top)
        .clipped()
    }
}

struct FramedScreen: View {
    let screenshot: NSImage
    let width: CGFloat
    let cornerRadius: CGFloat
    let bezel: CGFloat

    var body: some View {
        let height = width * screenshot.size.height / screenshot.size.width
        return Image(nsImage: screenshot)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .padding(bezel)
            .background(RoundedRectangle(cornerRadius: cornerRadius + bezel, style: .continuous).fill(Color(hex: 0x141416)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius + bezel, style: .continuous)
                .strokeBorder(Color(hex: 0x4A4A50), lineWidth: bezel * 0.22))
            .shadow(color: Brand.navyDeep.opacity(0.35), radius: 60, y: 30)
    }
}

/// Product page header, 3840 × 1646. Apple crops it heavily and puts icon, name and the Get button on top,
/// so the text stays in the middle (safe area about 1646 × 661).
struct HeaderArt: View {
    static let size = CGSize(width: 3840, height: 1646)
    let left: NSImage
    let right: NSImage
    let lines: (String, String)

    var body: some View {
        ZStack {
            Background(theme: .dark, size: Self.size)
            FramedScreen(screenshot: left, width: 660, cornerRadius: 96, bezel: 18)
                .rotationEffect(.degrees(-8))
                .offset(x: -1330, y: 260)
            FramedScreen(screenshot: right, width: 660, cornerRadius: 96, bezel: 18)
                .rotationEffect(.degrees(8))
                .offset(x: 1330, y: 260)
            VStack(spacing: 10) {
                Text(lines.0).foregroundStyle(.white)
                Text(lines.1).foregroundStyle(Brand.orange)
            }
            .font(.system(size: 168, weight: .heavy))
            .fixedSize()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }
}

/// Search results image, 3840 × 2560 (safe area about 2168 × 1030 in the middle).
struct SearchArt: View {
    static let size = CGSize(width: 3840, height: 2560)
    let front: NSImage
    let back: NSImage
    let kicker: String
    let headline: String
    let subline: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Background(theme: .light, size: Self.size)
            VStack(alignment: .leading, spacing: 0) {
                Text(kicker)
                    .font(.system(size: 76, weight: .bold))
                    .tracking(10)
                    .foregroundStyle(Brand.blue)
                Text(headline)
                    .font(.system(size: 190, weight: .heavy))
                    .foregroundStyle(Brand.ink)
                    .lineSpacing(-10)
                    .padding(.top, 30)
                Text(subline)
                    .font(.system(size: 92, weight: .medium))
                    .foregroundStyle(Brand.blue)
                    .padding(.top, 50)
            }
            .fixedSize()
            .frame(width: 1250, alignment: .leading)
            .offset(x: 740, y: 790)

            FramedScreen(screenshot: back, width: 720, cornerRadius: 106, bezel: 20)
                .rotationEffect(.degrees(6))
                .offset(x: 2930, y: 380)
            FramedScreen(screenshot: front, width: 780, cornerRadius: 114, bezel: 22)
                .rotationEffect(.degrees(-4))
                .offset(x: 2290, y: 560)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Captions

struct Language {
    let locale: String
    let iPhone: [Shot]
    let iPad: [Shot]
    let duoOuter: [Shot]
    let duoInner: [Shot]
    let header: (String, String)
    let search: (kicker: String, headline: String, subline: String)
}

let english = Language(
    locale: "en-US",
    iPhone: [
        Shot(raw: "iphone-overview", output: "01-overview", headline: "All your servers.\nOne screen.",
             subline: "Synology NAS and Proxmox hosts –\nstatus and warnings at a glance.", theme: .light),
        Shot(raw: "iphone-updates", output: "02-updates", headline: "Every update.\nOne list.",
             subline: "Packages, DSM and Proxmox –\ninstall several in one go.", theme: .dark),
        Shot(raw: "iphone-dashboard", output: "03-dashboard", headline: "Live dashboard.",
             subline: "Load, network, temperature,\nvolumes and drives.", theme: .light),
        Shot(raw: "iphone-containers", output: "04-containers", headline: "Containers\n& Compose.",
             subline: "Start, stop, restart –\nand read the logs.", theme: .dark),
        Shot(raw: "iphone-guests", output: "05-proxmox", headline: "VMs across\nthe cluster.",
             subline: "Start, shut down, snapshots –\nor open a shell.", theme: .light),
        Shot(raw: "iphone-backup", output: "06-backups", headline: "Backups in view.",
             subline: "Hyper Backup and vzdump jobs –\nback up now with one tap.", theme: .dark),
        Shot(raw: "iphone-notifications", output: "07-notifications", headline: "Know when\nit matters.",
             subline: "Storage problems, failed backups\nand crashed containers.", theme: .light),
        Shot(raw: "iphone-welcome", output: "08-private", headline: "Only your servers.",
             subline: "No account, no tracking, no relay.\nPasswords stay in the keychain.", theme: .dark),
    ],
    iPad: [
        Shot(raw: "ipad-dashboard", output: "01-dashboard", headline: "Your homelab at a glance.",
             subline: "Every server in the sidebar, live load, storage and drives next to it.", theme: .light),
        Shot(raw: "ipad-guests", output: "02-proxmox", headline: "VMs across the cluster.",
             subline: "Start, shut down, reboot, snapshots – or hand the shell to your terminal app.", theme: .dark),
        Shot(raw: "ipad-containers", output: "03-containers", headline: "Containers & Compose.",
             subline: "Start, stop and restart containers and projects – and read their logs.", theme: .light),
        Shot(raw: "ipad-backup", output: "04-backups", headline: "Backups in view.",
             subline: "Hyper Backup and vzdump jobs, destination status, back up now.", theme: .dark),
        Shot(raw: "ipad-packages", output: "05-packages", headline: "Packages up to date.",
             subline: "Update, start and stop – without the fiddly web interface.", theme: .light),
    ],
    duoOuter: [
        Shot(raw: "duo-outer-overview", output: "01-overview", headline: "All your servers.\nOne screen.",
             subline: "Synology NAS and Proxmox hosts –\nstatus at a glance.", theme: .light),
        Shot(raw: "duo-outer-updates", output: "02-updates", headline: "Every update.\nOne list.",
             subline: "Packages, DSM and Proxmox –\ninstall several in one go.", theme: .dark),
        Shot(raw: "duo-outer-dashboard", output: "03-dashboard", headline: "Live dashboard.",
             subline: "Load, network, temperature,\nvolumes and drives.", theme: .light),
        Shot(raw: "duo-outer-containers", output: "04-containers", headline: "Containers\n& Compose.",
             subline: "Start, stop, restart –\nand read the logs.", theme: .dark),
        Shot(raw: "duo-outer-notifications", output: "05-notifications", headline: "Know when\nit matters.",
             subline: "Storage problems, failed backups\nand crashed containers.", theme: .light),
    ],
    duoInner: [
        Shot(raw: "duo-inner-dashboard", output: "01-dashboard", headline: "Your homelab\nat a glance.",
             subline: "Unfolded: servers, areas and details side by side.", theme: .light),
        Shot(raw: "duo-inner-guests", output: "02-proxmox", headline: "VMs across\nthe cluster.",
             subline: "Start, shut down, snapshots – or open a shell.", theme: .dark),
        Shot(raw: "duo-inner-backup", output: "03-backups", headline: "Backups in view.",
             subline: "Hyper Backup and vzdump jobs – back up now.", theme: .light),
        Shot(raw: "duo-inner-containers", output: "04-containers", headline: "Containers\n& Compose.",
             subline: "Start, stop, restart – and read the logs.", theme: .dark),
        Shot(raw: "duo-inner-packages", output: "05-packages", headline: "Packages\nup to date.",
             subline: "Update, start and stop – from anywhere at home.", theme: .light),
    ],
    header: ("All your servers.", "One screen."),
    search: ("SYNOLOGY & PROXMOX", "Your homelab\nin one app", "Native. Free. Private.")
)

let german = Language(
    locale: "de-DE",
    iPhone: [
        Shot(raw: "iphone-overview", output: "01-uebersicht", headline: "Alle Server.\nEin Blick.",
             subline: "Synology-NAS und Proxmox-Hosts –\nStatus und Warnungen sofort sichtbar.", theme: .light),
        Shot(raw: "iphone-updates", output: "02-updates", headline: "Alle Updates.\nEine Liste.",
             subline: "Pakete, DSM und Proxmox –\nmehrere auf einmal installieren.", theme: .dark),
        Shot(raw: "iphone-dashboard", output: "03-dashboard", headline: "Live-Dashboard.",
             subline: "Last, Netzwerk, Temperatur,\nVolumes und Laufwerke.", theme: .light),
        Shot(raw: "iphone-containers", output: "04-container", headline: "Container\n& Compose.",
             subline: "Starten, stoppen, neu starten –\nund die Logs lesen.", theme: .dark),
        Shot(raw: "iphone-guests", output: "05-proxmox", headline: "VMs im\nganzen Cluster.",
             subline: "Starten, herunterfahren, Snapshots –\noder die Shell öffnen.", theme: .light),
        Shot(raw: "iphone-backup", output: "06-backups", headline: "Backups im Blick.",
             subline: "Hyper Backup und vzdump-Jobs –\nmit einem Tipp jetzt sichern.", theme: .dark),
        Shot(raw: "iphone-notifications", output: "07-mitteilungen", headline: "Bescheid,\nwenn es zählt.",
             subline: "Speicherprobleme, fehlgeschlagene\nBackups, abgestürzte Container.", theme: .light),
        Shot(raw: "iphone-welcome", output: "08-privat", headline: "Nur deine Server.",
             subline: "Kein Konto, kein Tracking, kein Relay.\nPasswörter bleiben im Schlüsselbund.", theme: .dark),
    ],
    iPad: [
        Shot(raw: "ipad-dashboard", output: "01-dashboard", headline: "Dein Homelab auf einen Blick.",
             subline: "Alle Server in der Seitenleiste, Last, Speicher und Laufwerke daneben.", theme: .light),
        Shot(raw: "ipad-guests", output: "02-proxmox", headline: "VMs im ganzen Cluster.",
             subline: "Starten, herunterfahren, Snapshots – oder die Shell in deiner Terminal-App.", theme: .dark),
        Shot(raw: "ipad-containers", output: "03-container", headline: "Container & Compose.",
             subline: "Container und Projekte starten, stoppen, neu starten – mit Logs.", theme: .light),
        Shot(raw: "ipad-backup", output: "04-backups", headline: "Backups im Blick.",
             subline: "Hyper Backup und vzdump-Jobs, Zielstatus, jetzt sichern.", theme: .dark),
        Shot(raw: "ipad-packages", output: "05-pakete", headline: "Pakete aktuell halten.",
             subline: "Aktualisieren, starten und stoppen – ohne fummelige Weboberfläche.", theme: .light),
    ],
    duoOuter: [
        Shot(raw: "duo-outer-overview", output: "01-uebersicht", headline: "Alle Server.\nEin Blick.",
             subline: "Synology-NAS und Proxmox-Hosts –\nStatus sofort sichtbar.", theme: .light),
        Shot(raw: "duo-outer-updates", output: "02-updates", headline: "Alle Updates.\nEine Liste.",
             subline: "Pakete, DSM und Proxmox –\nmehrere auf einmal installieren.", theme: .dark),
        Shot(raw: "duo-outer-dashboard", output: "03-dashboard", headline: "Live-Dashboard.",
             subline: "Last, Netzwerk, Temperatur,\nVolumes und Laufwerke.", theme: .light),
        Shot(raw: "duo-outer-containers", output: "04-container", headline: "Container\n& Compose.",
             subline: "Starten, stoppen, neu starten –\nund die Logs lesen.", theme: .dark),
        Shot(raw: "duo-outer-notifications", output: "05-mitteilungen", headline: "Bescheid,\nwenn es zählt.",
             subline: "Speicherprobleme, fehlgeschlagene\nBackups, abgestürzte Container.", theme: .light),
    ],
    duoInner: [
        Shot(raw: "duo-inner-dashboard", output: "01-dashboard", headline: "Dein Homelab\nauf einen Blick.",
             subline: "Aufgeklappt: Server, Bereiche und Details nebeneinander.", theme: .light),
        Shot(raw: "duo-inner-guests", output: "02-proxmox", headline: "VMs im\nganzen Cluster.",
             subline: "Starten, herunterfahren, Snapshots – oder die Shell öffnen.", theme: .dark),
        Shot(raw: "duo-inner-backup", output: "03-backups", headline: "Backups im Blick.",
             subline: "Hyper Backup und vzdump-Jobs – jetzt sichern.", theme: .light),
        Shot(raw: "duo-inner-containers", output: "04-container", headline: "Container\n& Compose.",
             subline: "Starten, stoppen, neu starten – und die Logs lesen.", theme: .dark),
        Shot(raw: "duo-inner-packages", output: "05-pakete", headline: "Pakete\naktuell halten.",
             subline: "Aktualisieren, starten und stoppen – von überall zu Hause.", theme: .light),
    ],
    header: ("Alle Server.", "Ein Blick."),
    search: ("SYNOLOGY & PROXMOX", "Dein Homelab\nin einer App", "Nativ. Kostenlos. Privat.")
)

// MARK: - Rendering

@MainActor
func writePNG(_ view: some View, size: CGSize, to url: URL) throws {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    // App Store Connect rejects images with an alpha channel: draw onto an opaque RGB context.
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(origin: .zero, size: size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func load(_ name: String) -> NSImage? {
    let url = raw.appendingPathComponent(name + ".png")
    guard let image = NSImage(contentsOf: url), let rep = image.representations.first else {
        print("  missing raw shot: \(name).png")
        return nil
    }
    // Use the pixel size, not the point size derived from the PNG's DPI.
    image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    return image
}

@MainActor
func run() throws {
    for language in [english, german] {
        print(language.locale)
        let sets: [(Device, [Shot])] = [
            (.iPhone, language.iPhone), (.iPhoneCompact, language.iPhone), (.iPad, language.iPad),
            (.duoOuter, language.duoOuter), (.duoInner, language.duoInner),
        ]
        for (device, shots) in sets {
            var count = 0
            for shot in shots {
                guard let image = load(shot.raw) else { continue }
                let url = output.appendingPathComponent("\(language.locale)/\(device.folder)/\(shot.output).png")
                try writePNG(Poster(device: device, shot: shot, screenshot: image), size: device.canvas, to: url)
                count += 1
            }
            print("  \(device.folder): \(count)")
        }
        if let left = load("iphone-overview"), let right = load("iphone-dashboard"), let back = load("iphone-updates") {
            try writePNG(HeaderArt(left: left, right: right, lines: language.header), size: HeaderArt.size,
                         to: output.appendingPathComponent("\(language.locale)/Creative/header-3840x1646.png"))
            try writePNG(SearchArt(front: left, back: back, kicker: language.search.kicker, headline: language.search.headline,
                                   subline: language.search.subline), size: SearchArt.size,
                         to: output.appendingPathComponent("\(language.locale)/Creative/search-3840x2560.png"))
            print("  Creative: 2")
        }
    }
}

try MainActor.assumeIsolated { try run() }
