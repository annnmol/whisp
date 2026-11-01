import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogsView: View {
    @State private var workspace = Workspace.shared
    @State private var follow = true
    @State private var copying = false
    @State private var feedback: String?
    private var logs: LiveLogs { workspace.liveLogs }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live logs").font(.title2.weight(.semibold))
                    Text(workspace.busy || workspace.testing ? workspace.activity : "Terminal output from this session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Follow output", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                Button("Copy logs") { copyLogs() }.disabled(logs.byteCount == 0 || copying)
                Button("Save log…") { saveLog() }.disabled(logs.byteCount == 0 || copying)
            }.padding(20)
            Divider()
            if logs.byteCount == 0 {
                ContentUnavailableView("No logs yet", systemImage: "terminal", description: Text("Run a tool check, install the environment or start transcription. Output appears here as it arrives."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogConsole(file: logs.file, revision: logs.revision, follow: follow)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                if logs.byteCount > LogConsole.previewBytes {
                    Text("Showing the latest output. Copy logs and Save log include the full captured session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = logs.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Circle().fill(workspace.busy || workspace.testing ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(workspace.busy || workspace.testing ? "Live · standard output and errors" : "Logs kept until you clear them or close the main window")
                        .font(.caption).foregroundStyle(.secondary)
                    if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Clear logs") { logs.clear(); feedback = nil }
                        .disabled(workspace.busy || workspace.testing || logs.byteCount == 0 || copying)
                }
            }.padding(16)
        }.frame(minWidth: 760, minHeight: 440)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
    }

    private func copyLogs() {
        guard let file = logs.file else { return }
        copying = true; feedback = nil
        Task {
            defer { copying = false }
            do {
                let text = try await Task.detached { try file.fullText() }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                feedback = "Copied"
            } catch { feedback = "Could not copy logs: \(error.localizedDescription)" }
        }
    }
    private func saveLog() {
        guard let file = logs.file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Whisp-log.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        copying = true; feedback = nil
        Task {
            defer { copying = false }
            do {
                try await Task.detached { try file.fullText().write(to: destination, atomically: true, encoding: .utf8) }.value
                feedback = "Log saved"
            } catch { feedback = "Could not save logs: \(error.localizedDescription)" }
        }
    }
}

/// Append incrementally rather than relaying a growing SwiftUI Text value.
/// Full history stays on disk; a bounded view keeps model processing responsive.
struct LogConsole: NSViewRepresentable {
    static let previewBytes = 1_048_576
    let file: SessionLog?
    let revision: Int
    let follow: Bool

    final class Coordinator {
        var id: UUID?
        var offset: UInt64 = 0
        var decoder = LogTextDecoder()
        var following = true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        text.layoutManager?.allowsNonContiguousLayout = true
        text.usesFindBar = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = revision
        guard let text = scroll.documentView as? NSTextView, let file else { return }
        let state = context.coordinator
        let size = file.state.bytes
        if state.id != file.id || state.offset > UInt64(size) {
            text.string = ""; state.id = file.id; state.offset = 0; state.decoder = LogTextDecoder()
        }
        if UInt64(size) - state.offset > UInt64(Self.previewBytes) {
            state.offset = UInt64(size - Self.previewBytes)
            text.string = ""; state.decoder = LogTextDecoder()
        }
        if let bytes = try? file.read(from: state.offset, maximum: Self.previewBytes), !bytes.isEmpty {
            state.offset += UInt64(bytes.count)
            let value = TerminalText.clean(state.decoder.decode(bytes))
            text.textStorage?.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]))
            let string = text.string as NSString
            if string.length > Self.previewBytes {
                let prefix = string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: string.length - Self.previewBytes))
                text.textStorage?.deleteCharacters(in: prefix)
            }
        }
        state.following = follow
        if follow {
            text.scrollToEndOfDocument(nil)
            DispatchQueue.main.async { [weak text, weak state] in
                if state?.following == true { text?.scrollToEndOfDocument(nil) }
            }
        }
    }
}
