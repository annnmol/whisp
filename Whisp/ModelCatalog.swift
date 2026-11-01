import Foundation

nonisolated struct WhisperModel: Codable, Identifiable, Sendable {
    let id: String
    let repository: String
    var cacheName: String { "models--" + repository.replacingOccurrences(of: "/", with: "--") }
}

nonisolated struct ModelAvailability: Identifiable, Sendable {
    let model: WhisperModel
    let snapshot: URL?
    let bytes: Int64
    let partial: Bool
    var id: String { model.id }
    var available: Bool { snapshot != nil }
}

nonisolated enum ModelCatalog {
    static let definitions: [WhisperModel] = {
        guard let url = Bundle.main.url(forResource: "WhisperModels", withExtension: "json"),
              let data = try? Data(contentsOf: url), let models = try? JSONDecoder().decode([WhisperModel].self, from: data) else { return [] }
        return models
    }()

    static func inventory(storage: Storage?) -> [ModelAvailability] {
        definitions.map { model in
            guard let storage, (try? storage.validate()) != nil else {
                return ModelAvailability(model: model, snapshot: nil, bytes: 0, partial: false)
            }
            let repo = storage.models.appendingPathComponent(model.cacheName, isDirectory: true)
            let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
            var candidates: [URL] = []
            if let reference = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !reference.isEmpty, reference.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                candidates.append(snapshots.appendingPathComponent(reference, isDirectory: true))
            }
            candidates += ((try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in candidates {
                if let bytes = completeSnapshot(candidate, inside: storage.models) {
                    return ModelAvailability(model: model, snapshot: candidate, bytes: bytes, partial: false)
                }
            }
            return ModelAvailability(model: model, snapshot: nil, bytes: 0, partial: FileManager.default.fileExists(atPath: repo.path))
        }
    }

    private static func completeSnapshot(_ folder: URL, inside root: URL) -> Int64? {
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        let required = ["config.json", "model.bin", "tokenizer.json"]
        var bytes: Int64 = 0
        func size(_ name: String) -> Int64? {
            let file = folder.appendingPathComponent(name).resolvingSymlinksInPath()
            guard file.path.hasPrefix(rootPath), let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return nil }
            return size.int64Value
        }
        for name in required { guard let size = size(name) else { return nil }; bytes += size }
        guard let vocabulary = size("vocabulary.json") ?? size("vocabulary.txt") else { return nil }
        return bytes + vocabulary
    }

    static func requireAvailable(_ model: String, storage: Storage) throws -> URL {
        guard let entry = inventory(storage: storage).first(where: { $0.id == model }), let snapshot = entry.snapshot else {
            throw WhispFailure(message: "Download \(model.isEmpty ? "a transcription model" : model) in Tools & setup before transcribing.")
        }
        return snapshot
    }
}

extension Backend {
    func modelInventory(storage: Storage?) -> [ModelAvailability] { ModelCatalog.inventory(storage: storage) }

    func removeModel(_ model: String, storage: Storage) throws {
        guard let definition = ModelCatalog.definitions.first(where: { $0.id == model }) else { throw WhispFailure(message: "Unknown model.") }
        try storage.withExclusiveAccess {
            let folder = storage.models.appendingPathComponent(definition.cacheName, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }
    }
}
