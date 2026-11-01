import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @State private var access = MCPAccess.shared
    @State private var revealToken = false
    @State private var portText = ""
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle("AI access (MCP)", isOn: Binding(get: { access.enabled }, set: { access.setEnabled($0) }))
                    .font(.headline)
                HStack(spacing: 8) {
                    Circle().fill(access.listening ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if access.enabled && !access.listening && access.error != nil {
                        Button("Retry") { access.setEnabled(true) }
                    }
                }
                Text("Connect a local AI app to open audio or video, start transcription, read transcripts and export files in your home folder. Actions appear in your Whisp window. Keep Whisp open while connected. Setup is managed by you in Tools.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if access.enabled {
                Section("Address") {
                    HStack {
                        Text("127.0.0.1").font(.body.monospaced())
                        Spacer()
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", text: $portText).frame(width: 76)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("MCP port")
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort).disabled(portText == String(access.port))
                    }
                    HStack {
                        Text(access.address).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        copyButton("address", text: access.address)
                    }
                }
                Section("Token") {
                    HStack(spacing: 10) {
                        Text(revealToken ? access.token : String(repeating: "•", count: 28))
                            .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(revealToken ? access.token : "Token hidden")
                        Button { revealToken.toggle() } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }.help(revealToken ? "Hide token" : "Show token")
                            .accessibilityLabel(revealToken ? "Hide token" : "Show token")
                        copyButton("token", text: access.token)
                        Button { access.newToken(); revealToken = false } label: {
                            Label("New token", systemImage: "arrow.counterclockwise")
                        }
                    }
                    Text("Use this address with Bearer token authentication in an AI app that supports local HTTP MCP connections. New token disconnects existing clients and replaces their access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = access.error {
                Section { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            if !access.activity.isEmpty {
                Section { Label(access.activity, systemImage: "sparkles").font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(access.port) }
        .onChange(of: access.port) { _, port in portText = String(port) }
    }

    private var status: String {
        if access.listening { return "Listening on 127.0.0.1:\(access.port) · \(access.clientCount) connected" }
        if access.error != nil { return "Unable to start AI access" }
        return access.enabled ? "Starting…" : "AI access is off"
    }

    private func applyPort() {
        access.setPort(Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    private func copyButton(_ label: String, text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = label
        } label: {
            Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
        }.disabled(text.isEmpty).help(copied == label ? "Copied \(label)" : "Copy \(label)")
            .accessibilityLabel("Copy \(label)")
            .onChange(of: text) { _, _ in if copied == label { copied = nil } }
    }
}
