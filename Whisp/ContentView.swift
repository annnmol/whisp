import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var workspace = Workspace.shared
    @State private var targeted = false
    @State private var showLog = false
    private let accent = Color(red: 0.39, green: 0.78, blue: 0.72)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if let receipt = workspace.exportReceipt { exportBanner(receipt); Divider() }
                if workspace.audio != nil { editor } else { emptyState }
                Divider()
                footer
            }
        }
        .frame(minWidth: 1020, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent).preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            workspace.acceptDrop(providers)
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(accent, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .background(WindowLifecycle(onClose: { workspace.close() }, onActivate: { workspace.activate() }).frame(width: 0, height: 0))
        .sheet(isPresented: $workspace.showTools) { ToolsView() }
        .alert("Something needs attention", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(accent)
                Text("Whisp").font(.title2.weight(.semibold))
            }.padding(24)
            Text("YOUR FILE").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 16)
            if let audio = workspace.audio {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(accent)
                        .frame(width: 34, height: 42).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(audio.source.lastPathComponent).font(.callout.weight(.medium)).lineLimit(2)
                        Text(audio.durationLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(workspace.result == nil ? "Ready to transcribe" : "Transcript ready")
                            .font(.caption2).foregroundStyle(workspace.result == nil ? Color.secondary : accent)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12)
            } else {
                Text("Your audio or video will appear here.").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 20)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("Local processing", systemImage: "lock.shield").font(.callout)
                Text("Your files stay on your Mac. Download models in Tools & setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Button { workspace.pickAudio() } label: {
                Label(workspace.audio == nil ? "Add file" : "Replace file", systemImage: "plus")
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.bordered).disabled(unavailable).padding(16)
            Divider()
            Button { workspace.showTools = true } label: {
                HStack {
                    Label("Tools & setup", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    Circle().fill(workspace.report?.ready == true ? accent : Color.secondary).frame(width: 7, height: 7)
                }.foregroundStyle(.secondary).padding(20)
            }.buttonStyle(.plain)
            SettingsLink {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 20)
            }.buttonStyle(.plain)
        }.frame(width: 242).background(Color.black.opacity(0.12))
    }
    private var unavailable: Bool { workspace.busy || workspace.testing }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.audio?.source.lastPathComponent ?? "Every word, a little clearer.").font(.headline).lineLimit(1)
                Text("Audio and video to text, subtitles and word timestamps.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.audio != nil {
                Button { workspace.removeAudio() } label: { Image(systemName: "trash") }
                    .disabled(unavailable).help("Remove file and temporary transcript")
            }
            if let result = workspace.result, result.files.count > 1 {
                Button("Save all…") { workspace.save(all: true) }.disabled(unavailable)
            }
        }.padding(.horizontal, 26).padding(.vertical, 20)
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 42, weight: .light)).foregroundStyle(accent)
                .frame(width: 100, height: 100).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            Text("From sound to words.").font(.system(size: 30, weight: .semibold))
            Text("Drop an audio or video file here, or choose one to get started.").foregroundStyle(.secondary)
            Button("Choose file…") { workspace.pickAudio() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(unavailable)
            Text("MP3, WAV, M4A, FLAC · MP4, MOV, MKV, WebM & more · Up to \(MediaInput.sizeLimitLabel) / 4 hours")
                .font(.caption).foregroundStyle(.tertiary)
            if workspace.report?.ready != true || !workspace.modelAvailable(workspace.options.model) {
                Button(workspace.report?.ready == true ? "Download a model in Tools & setup" : "Set up your tools first", systemImage: "wrench.and.screwdriver") { workspace.showTools = true }
                    .buttonStyle(.borderless).padding(.top, 10)
            }
            if let notice = workspace.notice { Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal) }
            Spacer()
            HStack(spacing: 28) {
                Label("Word timestamps", systemImage: "text.word.spacing")
                Label("Subtitle exports", systemImage: "captions.bubble")
                Label("Powered by WhisperX", systemImage: "waveform")
            }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Preset", selection: Binding(get: { workspace.preset }, set: { workspace.applyPreset($0) })) {
                    ForEach(TranscriptionPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                            .disabled((preset == .standard && !workspace.modelAvailable("small")) || (preset == .detailed && !workspace.modelAvailable("large-v3")))
                    }
                }.pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Picker("Language", selection: $workspace.options.language) {
                    ForEach(TranscriptionOptions.languages, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 230)
            }.disabled(unavailable)
            HStack(spacing: 16) {
                Picker("Output format", selection: $workspace.options.outputFormat) {
                    ForEach(TranscriptionOutputFormat.allCases) { Text($0.title).tag($0) }
                }.frame(width: 240).disabled(unavailable)
                Text(workspace.options.outputFormat == .json
                     ? "Includes word timestamps when alignment succeeds."
                     : workspace.options.outputFormat == .all
                     ? "Generate TXT, JSON, SRT, VTT and TSV in one run."
                     : "Generate a \(workspace.options.outputFormat.title) file.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                Label(workspace.options.model.isEmpty ? "No model selected" : workspace.options.model, systemImage: "cpu")
                Text("CPU / int8")
                Text(workspace.options.align ? "Word alignment on" : "Alignment off")
                Spacer()
                if let result = workspace.result {
                    Text("\(result.wordCount) timed words · \(result.language.uppercased())")
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Picker("Model", selection: Binding(get: { workspace.options.model }, set: { workspace.selectModel($0) })) {
                    Text("Download a model…").tag("").disabled(true)
                    ForEach(TranscriptionOptions.models, id: \.self) { model in
                        Text(workspace.modelAvailable(model) ? model : "\(model) — Not downloaded")
                            .tag(model).disabled(!workspace.modelAvailable(model))
                    }
                }.frame(width: 300).disabled(unavailable)
                Spacer()
                Button("Manage models…") { workspace.showTools = true }
            }
            if workspace.preset == .custom { advancedOptions }
            if let result = workspace.result {
                VStack(spacing: 0) {
                    HStack {
                        Label("Transcript", systemImage: "text.alignleft").font(.callout.weight(.medium))
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
                            workspace.notice = "Transcript copied."
                        } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                    }.padding(16)
                    Divider()
                    if result.previewTruncated {
                        Text("Preview shortened for this long transcript. Save the file to read the full result.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8)
                    }
                    ScrollView {
                        Text(result.text.isEmpty ? "No speech was found in this audio." : result.text)
                            .font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                    }
                }.background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.05)))
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    if unavailable { ProgressView().controlSize(.large) }
                    else { Image(systemName: "text.quote").font(.system(size: 35, weight: .light)).foregroundStyle(accent.opacity(0.8)) }
                    Text(unavailable ? workspace.activity : "Your transcript will appear here.").font(.title3.weight(.medium))
                    Text(unavailable ? "Processing locally. First use may download language alignment or speech-detection resources into your setup folder." : "Choose a preset, then start transcription.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            }
            if unavailable {
                HStack(spacing: 10) {
                    if let progress = workspace.progress { ProgressView(value: progress).frame(maxWidth: .infinity) }
                    else { ProgressView().controlSize(.small) }
                    Text(workspace.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let started = workspace.startedAt { TimelineView(.periodic(from: .now, by: 1)) { context in Text(Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .hourMinuteSecond))).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) } }
                }
            }
            if let notice = workspace.notice { Text(notice).font(.caption).foregroundStyle(accent).textSelection(.enabled) }
            HStack {
                if let result = workspace.result {
                    Picker("Export", selection: $workspace.selectedFormat) {
                        ForEach(TranscriptFormat.allCases.filter { result.files[$0] != nil }) { Text($0.title).tag($0) }
                    }.frame(width: 160).disabled(unavailable)
                    Button("Save \(workspace.selectedFormat.title)…") { workspace.save() }.disabled(unavailable)
                } else {
                    Text("Standard matches your basic command. Detailed uses large-v3 + Silero.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    do { try workspace.startTranscription() } catch { workspace.showFailure(error) }
                } label: {
                    Label(workspace.result == nil ? "Transcribe" : "Transcribe again", systemImage: "waveform")
                        .padding(.horizontal, 7).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(unavailable || !workspace.modelAvailable(workspace.options.model))
            }
        }.padding(24)
    }
    private var advancedOptions: some View {
        HStack(spacing: 18) {
            Picker("VAD", selection: $workspace.options.vad) {
                Text("Silero").tag("silero"); Text("Pyannote").tag("pyannote")
            }.frame(width: 160)
            Stepper("Batch \(workspace.options.batchSize)", value: $workspace.options.batchSize, in: 1...32).frame(width: 110)
            Stepper("Chunk \(workspace.options.chunkSize)s", value: $workspace.options.chunkSize, in: 5...30).frame(width: 130)
        }.font(.caption).disabled(unavailable)
    }
    private var footer: some View {
        HStack(spacing: 14) {
            Label(unavailable ? workspace.activity : "Your original file is kept untouched", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Logs", systemImage: "terminal") { openWindow(id: "logs") }.buttonStyle(.borderless)
            if !workspace.log.isEmpty {
                Button("Activity") { showLog = true }.buttonStyle(.borderless)
            }
            if unavailable {
                Button(workspace.cancelling ? "Cancelling…" : "Cancel") { workspace.cancelOperation() }.disabled(workspace.cancelling)
            }
        }.padding(.horizontal, 24).padding(.vertical, 14)
            .sheet(isPresented: $showLog) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Activity").font(.title2.weight(.semibold)); Spacer(); Button("Done") { showLog = false } }
                    ScrollView { Text(workspace.log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Text("Shows the most recent tool output. Tokens are never included in commands.").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(width: 720, height: 480)
            }
    }
    private func exportBanner(_ receipt: ExportReceipt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.title).font(.callout.weight(.medium))
                Text(receipt.files.first?.deletingLastPathComponent().path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(receipt.files) }
            Button { workspace.exportReceipt = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss export confirmation")
        }.padding(.horizontal, 24).padding(.vertical, 12).background(accent.opacity(0.08))
    }
}
