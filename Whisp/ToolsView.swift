import SwiftUI
import AppKit

struct ToolsView: View {
    @State private var workspace = Workspace.shared
    @State private var confirmClear = false
    @State private var confirmModels = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private var unavailable: Bool { workspace.busy || workspace.testing }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your transcription tools").font(.title2.weight(.semibold))
                    Text("Install Python and FFmpeg yourself. Whisp checks the rest.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Logs", systemImage: "terminal") { openWindow(id: "logs") }
                Button("Done") { dismiss() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("1. Check your installed tools", systemImage: "checkmark.seal").font(.headline)
                            toolRow("Python", value: workspace.report?.pythonVersion, path: workspace.report?.python)
                            toolRow("FFmpeg", value: workspace.report?.ffmpeg == nil ? nil : "Found", path: workspace.report?.ffmpeg)
                            toolRow("FFprobe", value: workspace.report?.ffprobe == nil ? nil : "Found", path: workspace.report?.ffprobe)
                            HStack {
                                Link("Get Python ↗", destination: URL(string: "https://www.python.org/downloads/macos/")!)
                                Link("Get FFmpeg ↗", destination: URL(string: "https://ffmpeg.org/download.html#build-mac")!)
                                Spacer()
                                Button(workspace.testing ? "Testing…" : "Test tools") { Task { await workspace.testTools() } }
                                    .buttonStyle(.borderedProminent).disabled(unavailable)
                            }
                            DisclosureGroup("Custom tool locations") {
                                VStack(spacing: 10) {
                                    HStack {
                                        TextField("Python executable (optional)", text: $workspace.pythonPath).textFieldStyle(.roundedBorder)
                                        Button("Browse…") { choosePython() }
                                    }
                                    HStack {
                                        TextField("FFmpeg / FFprobe folder (optional)", text: $workspace.toolsFolder).textFieldStyle(.roundedBorder)
                                        Button("Browse…") { chooseToolsFolder() }
                                    }
                                }.padding(.top, 8).disabled(unavailable)
                            }
                            Text("Python 3.11 recommended; 3.10–3.13 accepted. Python 3.14 cannot create a compatible environment.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("2. Choose your setup folder", systemImage: "folder").font(.headline)
                            Text(workspace.storage?.root.path ?? "No setup folder selected")
                                .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Whisp creates a Whisp Data subfolder containing its environment, models, caches and temporary files. Keep it in the same location.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(workspace.storage == nil ? "Choose folder…" : "Change folder…") { workspace.chooseFolder() }.disabled(unavailable)
                                if let root = workspace.storage?.root { Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path) } }
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("3. Install the WhisperX environment", systemImage: "shippingbox").font(.headline)
                            toolRow("WhisperX", value: workspace.report?.whisperVersion, path: workspace.storage?.environment.path)
                            Text("Downloads WhisperX 3.8.6 and its dependencies into your selected folder. No global Python or FFmpeg installation. After installation, download the transcription models you want below. Large models may use several GB.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(workspace.report?.environmentWorks == true ? "Repair environment" : "Install environment") { Task { await workspace.install() } }
                                .disabled(unavailable || workspace.storage == nil)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ModelManagerView()
                    if let report = workspace.report {
                        Text(report.message).font(.callout).foregroundStyle(report.ready ? Color.green : Color.secondary).textSelection(.enabled)
                        Text("Last tested: \(report.checkedAt.formatted(date: .abbreviated, time: .shortened)). Results are remembered; tools are rechecked before processing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Button("Clear temporary data…", role: .destructive) { confirmClear = true }
                        Spacer()
                        Button("Remove models & cache…", role: .destructive) { confirmModels = true }
                    }.disabled(unavailable)
                    Text("Closing the window clears temporary transcripts. Saved exports, models and the environment are kept. After an unexpected exit, abandoned temporary files are cleared when the setup folder is next opened.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if unavailable {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(workspace.activity).font(.callout).lineLimit(1)
                    Spacer()
                    Button(workspace.cancelling ? "Cancelling…" : "Cancel") { workspace.cancelOperation() }.disabled(workspace.cancelling)
                }
            }
            if let notice = workspace.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(5).textSelection(.enabled) }
        }.padding(26).frame(width: 660, height: 710)
        .confirmationDialog("Clear temporary transcripts?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear temporary data", role: .destructive) { workspace.clearTemporaryData() }
        } message: { Text("Unexported transcripts and session logs will be discarded. Your original files, saved exports and installed models are kept.") }
        .confirmationDialog("Remove downloaded models and caches?", isPresented: $confirmModels, titleVisibility: .visible) {
            Button("Remove models & cache", role: .destructive) { Task { await workspace.removeModels() } }
        } message: { Text("The Python environment is kept. Download the models you want again in this panel; this may take time and several GB.") }
    }
    private func toolRow(_ name: String, value: String?, path: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: value == nil ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(value == nil ? Color.secondary : Color.green)
            Text(name).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(value ?? "Not tested / not found").font(.callout)
                if let path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            }
        }
    }
    private func choosePython() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Choose an installed compatible Python executable, such as python3.11."
        if panel.runModal() == .OK, let url = panel.url { workspace.pythonPath = url.path }
    }
    private func chooseToolsFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { workspace.toolsFolder = url.path }
    }
}
