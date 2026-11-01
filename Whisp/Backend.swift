import Foundation

actor Backend {
    static let shared = Backend()
    private var worker: String {
        get throws {
            guard let url = Bundle.main.url(forResource: "worker", withExtension: "py") else {
                throw WhispFailure(message: "Whisp’s transcription worker is missing. Rebuild or reinstall Whisp.")
            }
            return url.path
        }
    }

    func check(storage: Storage?, pythonPath: String, toolsFolder: String, cancellation: OperationCancellation, sessionLog: SessionLog? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> ToolReport {
        var report = ToolReport()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Whisp-Tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ executable: String, _ args: [String], timeout: Double = 10) throws -> String {
            try ProcessRunner.run(executable, args, log: folder.appendingPathComponent(UUID().uuidString), timeout: timeout, cancellation: cancellation, sessionLog: sessionLog, progress: progress)
        }
        let candidates = executableCandidates(names: ["python3.11", "python3.12", "python3.13", "python3.10", "python3"], folder: "", explicit: pythonPath)
        for path in candidates {
            try cancellation.check()
            guard let output = try? run(path, ["-I", "-c", "import sys; print('.'.join(map(str,sys.version_info[:3])))"]),
                  let version = AppVersion(output), version.components[0] == 3, (10...13).contains(version.components[1]) else { continue }
            report.python = path; report.pythonVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        for (name, key) in [("ffmpeg", \ToolReport.ffmpeg), ("ffprobe", \ToolReport.ffprobe)] {
            for path in executableCandidates(names: [name], folder: toolsFolder) {
                try cancellation.check()
                if (try? run(path, ["-version"])) != nil { report[keyPath: key] = path; break }
            }
        }
        var environmentError: String?
        if let storage, FileManager.default.isExecutableFile(atPath: storage.python.path) {
            do {
                try storage.validate()
                let job = try storage.jobDirectory()
                defer { storage.removeJob(job) }
                var env = storage.processEnvironment(ffmpeg: report.ffmpeg)
                env["TMPDIR"] = job.path
                let output = try ProcessRunner.run(storage.python.path, ["-s", try worker, "check", "--root", storage.root.path],
                    environment: env, directory: job, log: job.appendingPathComponent("check.log"), timeout: 120, cancellation: cancellation, sessionLog: sessionLog, progress: progress)
                if let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("WHISP_EVENT ") }),
                   let data = line.dropFirst(12).data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = json["version"] as? String {
                    report.environmentWorks = true; report.whisperVersion = version
                }
            } catch {
                try cancellation.check()
                environmentError = String(error.localizedDescription.suffix(1200))
            }
        }
        var missing: [String] = []
        if report.python == nil { missing.append("Install Python 3.11–3.13, or choose a compatible Python executable.") }
        if report.ffmpeg == nil || report.ffprobe == nil { missing.append("Install FFmpeg with FFprobe, or choose their bin folder.") }
        if !report.environmentWorks { missing.append(storage == nil ? "Choose a setup folder, then install the environment." : "Install or repair the WhisperX environment in your setup folder.") }
        report.message = report.ready ? "All tools are ready. WhisperX \(report.whisperVersion ?? "") · CPU / int8." : missing.joined(separator: "\n")
        if let environmentError { report.message += "\n\nEnvironment check: \(environmentError)" }
        return report
    }

    private func executableCandidates(names: [String], folder: String, explicit: String = "") -> [String] {
        if !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = NSString(string: explicit.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? [path] : []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ([folder, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.pyenv/shims", "/Library/Frameworks/Python.framework/Versions/3.11/bin", "/Library/Frameworks/Python.framework/Versions/3.12/bin", "/Library/Frameworks/Python.framework/Versions/3.13/bin"] +
                           (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") + ["/usr/bin", "/bin"]).filter { !$0.isEmpty }
        var seen = Set<String>()
        return directories.flatMap { directory in names.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path } }
            .filter { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }
    }

    func install(storage: Storage, python: String, ffmpeg: String?, cancellation: OperationCancellation, sessionLog: SessionLog? = nil, progress: @Sendable (String) -> Void) throws {
        try storage.prepare()
        let job = try storage.jobDirectory()
        defer { storage.removeJob(job) }
        var env = storage.processEnvironment(ffmpeg: ffmpeg)
        env["TMPDIR"] = job.path
        _ = try ProcessRunner.run(python, ["-s", try worker, "install", "--root", storage.root.path],
            environment: env, directory: job, log: job.appendingPathComponent("setup.log"), timeout: 3600,
            cancellation: cancellation, sessionLog: sessionLog, progress: progress)
    }

    func downloadModel(_ model: String, storage: Storage, cancellation: OperationCancellation, sessionLog: SessionLog?, progress: @Sendable (String) -> Void) throws {
        try storage.prepare()
        guard ModelCatalog.definitions.contains(where: { $0.id == model }), FileManager.default.isExecutableFile(atPath: storage.python.path) else {
            throw WhispFailure(message: "Install the WhisperX environment, then choose a supported model.")
        }
        let job = try storage.jobDirectory()
        defer { storage.removeJob(job) }
        var env = storage.processEnvironment()
        env["TMPDIR"] = job.path
        _ = try ProcessRunner.run(storage.python.path, ["-s", try worker, "download", "--root", storage.root.path, "--model", model],
            environment: env, directory: job, log: job.appendingPathComponent("download.log"), timeout: 7200,
            cancellation: cancellation, sessionLog: sessionLog, progress: progress)
        try cancellation.check()
        _ = try ModelCatalog.requireAvailable(model, storage: storage)
    }

    func inspect(_ url: URL, ffprobe: String, cancellation: OperationCancellation, sessionLog: SessionLog? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> AudioAsset {
        let input = url.standardizedFileURL.resolvingSymlinksInPath()
        let bytes = try MediaInput.validateFile(input)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("Whisp-Probe-\(UUID().uuidString)")
        let output = try ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "format=duration:stream=codec_type,duration", "-of", "json", input.path],
            log: log, timeout: 20, cancellation: cancellation, sessionLog: sessionLog, progress: progress)
        guard let data = output.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], streams.contains(where: { $0["codec_type"] as? String == "audio" }) else {
            throw WhispFailure(message: "This file does not contain a supported audio track. Choose audio, or a video with sound.")
        }
        let format = json["format"] as? [String: Any]
        let duration = Double(format?["duration"] as? String ?? "") ?? streams.compactMap { Double($0["duration"] as? String ?? "") }.max() ?? 0
        guard duration.isFinite, duration > 0, duration <= 14_400 else {
            throw WhispFailure(message: "Choose an audio or video file with a readable duration of up to four hours.")
        }
        return AudioAsset(id: UUID(), source: input, bytes: bytes, duration: duration)
    }

    func transcribe(_ audio: AudioAsset, storage: Storage, output: URL, options: TranscriptionOptions,
                    ffmpeg: String, cancellation: OperationCancellation, sessionLog: SessionLog? = nil, progress: @Sendable (String) -> Void) throws -> TranscriptResult {
        try storage.validate()
        try MediaInput.validateFile(audio.source)
        try options.validate()
        let modelPath = try ModelCatalog.requireAvailable(options.model, storage: storage)
        let request = output.appendingPathComponent("request.json")
        let encoded = try JSONEncoder().encode(options)
        let optionsObject = try JSONSerialization.jsonObject(with: encoded)
        try JSONSerialization.data(withJSONObject: ["audio": audio.source.path, "output": output.path, "options": optionsObject, "modelPath": modelPath.path]).write(to: request, options: .atomic)
        defer { try? FileManager.default.removeItem(at: request) }
        var env = storage.processEnvironment(ffmpeg: ffmpeg)
        env["TMPDIR"] = output.path
        _ = try ProcessRunner.run(storage.python.path, ["-s", try worker, "transcribe", "--root", storage.root.path, "--request", request.path],
            environment: env, directory: output, log: output.appendingPathComponent("process.log"), timeout: 21_600,
            cancellation: cancellation, sessionLog: sessionLog, progress: progress)
        try cancellation.check()
        let basename = audio.source.deletingPathExtension().lastPathComponent
        var files: [TranscriptFormat: URL] = [:]
        for format in options.outputFormat.formats {
            let file = output.appendingPathComponent(basename).appendingPathExtension(format.rawValue)
            if FileManager.default.fileExists(atPath: file.path) { files[format] = file }
        }
        let jsonFile = output.appendingPathComponent(basename).appendingPathExtension("json")
        guard !files.isEmpty, FileManager.default.fileExists(atPath: jsonFile.path),
              options.outputFormat.formats.allSatisfy({ files[$0] != nil }) else {
            throw WhispFailure(message: "WhisperX completed without the expected transcript files. Check the audio and retry.")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: jsonFile.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 67_108_864 else { throw WhispFailure(message: "The transcript is too large to preview. Try a shorter audio file.") }
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonFile)) as? [String: Any],
              let segments = metadata["segments"] as? [[String: Any]] else {
            throw WhispFailure(message: "Could not read the completed transcript.")
        }
        let words = segments.reduce(0) { $0 + (($1["words"] as? [[String: Any]])?.filter { $0["start"] is NSNumber && $0["end"] is NSNumber }.count ?? 0) }
        let fullText = segments.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        let text = String(fullText.prefix(250_000))
        let truncated = fullText.count > 250_000
        return TranscriptResult(directory: output, files: files, text: text, language: metadata["language"] as? String ?? options.language, wordCount: words, previewTruncated: truncated)
    }

    func export(_ sources: [(URL, URL)], cancellation: OperationCancellation) throws -> ExportReceipt {
        var saved: [URL] = []
        do {
            for (source, destination) in sources {
                try cancellation.check()
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw WhispFailure(message: "\(destination.lastPathComponent) already exists. Choose another name or folder.")
                }
                try FileManager.default.copyItem(at: source, to: destination)
                saved.append(destination)
            }
            try cancellation.check()
            return ExportReceipt(files: saved)
        } catch {
            for url in saved { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    func removeModels(storage: Storage) throws {
        try storage.validate()
        try storage.withExclusiveAccess {
            for url in [storage.models, storage.cache] {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            try storage.prepare()
        }
    }
}
