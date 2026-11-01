import Foundation
import Darwin

/// Only a marked Whisp Data directory and known children are managed by the app.
nonisolated struct Storage: Sendable {
    let root: URL
    var environment: URL { root.appendingPathComponent("environment", isDirectory: true) }
    var python: URL { environment.appendingPathComponent("bin/python") }
    var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    var temporary: URL { root.appendingPathComponent("temporary", isDirectory: true) }
    private var marker: URL { root.appendingPathComponent(".whisp-data") }

    static func choose(_ parent: URL) throws -> Storage {
        let storage = Storage(root: parent.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Whisp Data", isDirectory: true))
        if FileManager.default.fileExists(atPath: storage.root.path) {
            try storage.validate()
        } else {
            try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: false)
            try Data("Whisp managed data v1\n".utf8).write(to: storage.marker, options: .withoutOverwriting)
        }
        try storage.prepare()
        return storage
    }

    func validate() throws {
        guard root.isFileURL else { throw WhispFailure(message: "Choose a local folder.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              try String(contentsOf: marker, encoding: .utf8) == "Whisp managed data v1\n" else {
            throw WhispFailure(message: "This Whisp Data folder was not created by Whisp. Choose a different parent folder.")
        }
        for url in [environment, models, cache, temporary] {
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
                throw WhispFailure(message: "Managed folders cannot be symbolic links. Choose a different setup folder.")
            }
        }
    }

    func prepare() throws {
        try validate()
        for url in [models, cache, temporary, cache.appendingPathComponent("nltk"), cache.appendingPathComponent("huggingface"), cache.appendingPathComponent("torch")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Clear abandoned jobs after a crash; never touch another running instance.
        let entries = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
        for url in entries {
            guard let raw = url.lastPathComponent.split(separator: "-").first, let pid = Int32(raw), pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }

    func jobDirectory() throws -> URL {
        try prepare()
        let url = temporary.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func removeJob(_ url: URL) {
        guard (try? validate()) != nil, url.deletingLastPathComponent().standardizedFileURL.path == temporary.standardizedFileURL.path,
              url.lastPathComponent.hasPrefix("\(getpid())-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try validate()
        let descriptor = open(root.appendingPathComponent(".operation.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw WhispFailure(message: "Could not access the setup folder.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw WhispFailure(message: "Another Whisp process is using this setup folder. Wait for it to finish.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func processEnvironment(ffmpeg: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let paths: [String] = [ffmpeg.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path(percentEncoded: false) },
                     environment.appendingPathComponent("bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].compactMap { $0 }
        env["PATH"] = paths.joined(separator: ":")
        env["VIRTUAL_ENV"] = environment.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        env["PYTHONPYCACHEPREFIX"] = cache.appendingPathComponent("pycache").path
        env["PIP_CACHE_DIR"] = cache.appendingPathComponent("pip").path
        env["HF_HOME"] = cache.appendingPathComponent("huggingface").path
        env["HF_HUB_CACHE"] = cache.appendingPathComponent("huggingface/hub").path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
        env["TQDM_MININTERVAL"] = "1"
        env.removeValue(forKey: "TRANSFORMERS_CACHE")
        env["HF_XET_CACHE"] = cache.appendingPathComponent("huggingface/xet").path
        env["TORCH_HOME"] = cache.appendingPathComponent("torch").path
        env["XDG_CACHE_HOME"] = cache.path
        env["NLTK_DATA"] = cache.appendingPathComponent("nltk").path
        env["MPLCONFIGDIR"] = cache.appendingPathComponent("matplotlib").path
        env["NUMBA_CACHE_DIR"] = cache.appendingPathComponent("numba").path
        env["TOKENIZERS_PARALLELISM"] = "false"
        return env
    }
}
