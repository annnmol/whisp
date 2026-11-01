import SwiftUI

struct ModelManagerView: View {
    @State private var workspace = Workspace.shared
    @State private var deleting: String?
    @State private var confirmDelete = false
    private var unavailable: Bool { workspace.busy || workspace.testing }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("4. Download a transcription model", systemImage: "externaldrive.badge.icloud").font(.headline)
                    Spacer()
                    Button("Refresh") { Task { await workspace.refreshModels() } }
                        .disabled(unavailable || workspace.refreshingModels)
                }
                Text("Only downloaded models can be selected for transcription. Downloads stay inside your setup folder and can be cancelled or resumed.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ModelCatalog.definitions) { model in
                    let entry = workspace.models.first { $0.id == model.id }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: entry?.available == true ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(entry?.available == true ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.id).font(.callout.weight(.medium))
                                Text(status(model.id, entry: entry)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry?.available == true {
                                if workspace.options.model == model.id {
                                    Label("Selected", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                                } else {
                                    Button("Use") { workspace.selectModel(model.id) }.disabled(unavailable)
                                }
                            } else if workspace.downloadingModel != model.id {
                                Button(entry?.partial == true ? "Resume" : "Download") { Task { await workspace.downloadModel(model.id) } }
                                    .disabled(unavailable || workspace.report?.environmentWorks != true || workspace.storage == nil)
                            }
                            if entry?.available == true || entry?.partial == true {
                                Button { deleting = model.id; confirmDelete = true } label: { Image(systemName: "trash") }
                                    .help("Delete \(model.id)").accessibilityLabel("Delete \(model.id)").disabled(unavailable)
                            }
                        }
                        if workspace.downloadingModel == model.id {
                            if let value = workspace.modelDownloadProgress { ProgressView(value: value) }
                            else { HStack { ProgressView().controlSize(.small); Text("Preparing download…").font(.caption).foregroundStyle(.secondary) } }
                            if workspace.modelDownloadTotal > 0 {
                                Text("\(ByteCountFormatter.string(fromByteCount: workspace.modelDownloadBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: workspace.modelDownloadTotal, countStyle: .file))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.id != ModelCatalog.definitions.last?.id { Divider() }
                }
                Text("Language alignment and speech-detection resources may download separately on first use, inside the same setup folder. Live logs show their output.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await workspace.refreshModels() }
        .confirmationDialog("Delete this downloaded model?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let deleting {
                Button("Delete \(deleting)", role: .destructive) { Task { await workspace.deleteModel(deleting) } }
            }
        } message: { Text("The model will be unavailable until downloaded again. Other models, the environment and saved transcripts are kept.") }
    }

    private func status(_ model: String, entry: ModelAvailability?) -> String {
        if workspace.downloadingModel == model { return "Downloading…" }
        if let entry, entry.available { return "Available · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))" }
        if entry?.partial == true { return "Incomplete download" }
        return "Not downloaded"
    }
}
