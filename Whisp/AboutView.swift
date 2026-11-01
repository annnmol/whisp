import SwiftUI
import AppKit

struct AboutView: View {
    @State private var updates = AppUpdates.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 72, height: 72)))
                        .resizable().scaledToFit().frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Whisp").font(.title.weight(.semibold))
                        Text("Version \(AppInfo.version) (\(AppInfo.build))")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Made by Anmol Tanwar").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Text("Turn audio into text, subtitles and word timestamps. Processing runs locally on your Mac, powered by WhisperX.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Updates") {
                HStack(spacing: 12) {
                    if updates.checking {
                        ProgressView().controlSize(.small)
                        Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(updates.message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let update = updates.available {
                        Link(destination: update.destination) {
                            Label("Update to \(update.version)", systemImage: "arrow.down.circle.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color(red: 0.12, green: 0.48, blue: 0.27), in: Capsule())
                        }.buttonStyle(.plain)
                            .help(update.dmgURL == nil ? "View the new release on GitHub" : "Download the Apple Silicon DMG")
                    }
                }
                if let update = updates.available {
                    Text(update.dmgURL == nil
                         ? "Open the release on GitHub to see available downloads."
                         : "Downloads the Apple Silicon DMG. Open it and drag Whisp into Applications to install the update.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let checked = updates.lastChecked {
                        Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for updates") { Task { await updates.check(force: true) } }
                        .disabled(updates.checking)
                }
            }
            Section {
                HStack {
                    Link("GitHub", destination: AppInfo.github)
                    Spacer()
                    Link("Release history", destination: AppInfo.releases)
                }
                Text("Open source · MIT License")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await updates.check() }
    }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Whisp") { openWindow(id: "about") }
        }
    }
}
