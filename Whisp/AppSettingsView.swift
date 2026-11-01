import SwiftUI

struct AppSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var workspace = Workspace.shared
    var body: some View {
        TabView {
            Form {
                Section("Transcription") {
                    Picker("Default export format", selection: $workspace.selectedFormat) {
                        ForEach(TranscriptFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Align word timestamps", isOn: $workspace.options.align)
                        .disabled(workspace.busy || workspace.testing)
                    Text("Alignment uses a language-specific model. Word timestamps appear in JSON when alignment succeeds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    Text(workspace.storage?.root.path ?? "Choose a setup folder in Tools & setup.")
                        .font(.callout.monospaced()).textSelection(.enabled)
                    Button("Tools & setup…") { openWindow(id: "main"); workspace.showTools = true }
                    Text("Temporary transcripts clear when the main window closes. Your installed environment and downloaded models remain available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            MCPSettingsView().tabItem { Label("AI access", systemImage: "sparkles") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 680, height: 570).preferredColorScheme(.dark)
    }
}
