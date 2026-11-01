import Foundation

nonisolated struct WhispFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct ToolReport: Codable, Sendable {
    var python: String?
    var pythonVersion: String?
    var ffmpeg: String?
    var ffprobe: String?
    var whisperVersion: String?
    var environmentWorks = false
    var message = "Test your tools to get started."
    var checkedAt = Date()
    var ready: Bool { python != nil && ffmpeg != nil && ffprobe != nil && environmentWorks }
}

nonisolated enum TranscriptFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case txt, json, srt, vtt, tsv
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

nonisolated enum TranscriptionPreset: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard", detailed = "Detailed", custom = "Custom"
    var id: String { rawValue }
}

nonisolated enum TranscriptionOutputFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case all, json, txt, srt, vtt, tsv
    var id: String { rawValue }
    var title: String { self == .all ? "All formats" : rawValue.uppercased() }
    var formats: [TranscriptFormat] {
        self == .all ? TranscriptFormat.allCases : TranscriptFormat(rawValue: rawValue).map { [$0] } ?? []
    }
}

nonisolated struct TranscriptionOptions: Codable, Sendable {
    var model = "small"
    var language = "hi"
    var vad = "pyannote"
    var batchSize = 8
    var chunkSize = 30
    var align = true
    var outputFormat: TranscriptionOutputFormat = .all

    init() {}

    private enum CodingKeys: String, CodingKey {
        case model, language, vad, batchSize, chunkSize, align, outputFormat
    }

    // Keep existing saved options when upgrading from a version without this field.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? "small"
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "hi"
        vad = try values.decodeIfPresent(String.self, forKey: .vad) ?? "pyannote"
        batchSize = try values.decodeIfPresent(Int.self, forKey: .batchSize) ?? 8
        chunkSize = try values.decodeIfPresent(Int.self, forKey: .chunkSize) ?? 30
        align = try values.decodeIfPresent(Bool.self, forKey: .align) ?? true
        outputFormat = try values.decodeIfPresent(TranscriptionOutputFormat.self, forKey: .outputFormat) ?? .all
    }
    static var models: [String] { ModelCatalog.definitions.map(\.id) }
    static let languages: [(String, String)] = [
        ("auto", "Detect automatically"), ("hi", "Hindi"), ("en", "English"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("ru", "Russian"), ("ur", "Urdu"), ("te", "Telugu"), ("ml", "Malayalam")
    ]
    mutating func apply(_ preset: TranscriptionPreset) {
        guard preset != .custom else { return }
        model = preset == .detailed ? "large-v3" : "small"
        vad = preset == .detailed ? "silero" : "pyannote"
        batchSize = preset == .detailed ? 1 : 8
        chunkSize = preset == .detailed ? 15 : 30
        if preset == .detailed { outputFormat = .json }
    }
    func validate() throws {
        guard Self.models.contains(model), Self.languages.contains(where: { $0.0 == language }),
              ["silero", "pyannote"].contains(vad), (1...32).contains(batchSize), (5...30).contains(chunkSize) else {
            throw WhispFailure(message: "Choose valid transcription options.")
        }
    }
}

nonisolated struct AudioAsset: Sendable {
    let id: UUID
    let source: URL
    let bytes: Int64
    let duration: Double
    var durationLabel: String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

nonisolated struct TranscriptResult: Sendable {
    let directory: URL
    let files: [TranscriptFormat: URL]
    let text: String
    let language: String
    let wordCount: Int
    let previewTruncated: Bool
}

nonisolated struct ExportReceipt: Sendable {
    let files: [URL]
    var title: String { files.count == 1 ? "Saved \(files[0].lastPathComponent)" : "Saved \(files.count) files" }
}
