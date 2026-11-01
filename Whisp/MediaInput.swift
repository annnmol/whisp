import AppKit
import UniformTypeIdentifiers

nonisolated enum MediaInput {
    static let maximumFileBytes: Int64 = 200_000_000
    static let sizeLimitLabel = "200 MB"
    static let pickerTypes: [UTType] = [.audio, .movie, .video] +
        ["mp3", "wav", "m4a", "flac", "aac", "aiff", "ogg", "opus", "mp4", "mov", "m4v", "mkv", "webm", "avi"]
            .compactMap { UTType(filenameExtension: $0) }

    @discardableResult
    static func validateFile(_ source: URL) throws -> Int64 {
        guard source.isFileURL else { throw WhispFailure(message: "Choose a local audio or video file.") }
        let input = source.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: input.path),
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
            throw WhispFailure(message: "Choose a readable audio or video file.")
        }
        guard bytes.int64Value <= maximumFileBytes else {
            throw WhispFailure(message: "This file exceeds the \(sizeLimitLabel) limit. Choose a smaller audio or video file.")
        }
        return bytes.int64Value
    }

    @MainActor static func makePicker() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = pickerTypes
        panel.prompt = "Choose file"
        panel.message = "Choose audio or video up to \(sizeLimitLabel). Videos must contain an audio track."
        return panel
    }

    @MainActor static func droppedFile(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let text = item as? String {
                    url = URL(string: text)
                } else {
                    url = nil
                }
                guard let url, url.isFileURL else {
                    continuation.resume(throwing: WhispFailure(message: "Could not read the dropped file. Drag a local audio or video file from Finder."))
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
