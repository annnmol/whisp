import Foundation
import CoreFoundation

@MainActor enum MCPTools {
    private static let string: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 4096]
    static let catalog: [[String: Any]] = [
        tool("get_status", "Read Whisp audio, transcription job state, progress, outputs and setup status. Poll after start_transcription until completed, failed or cancelled.", [:], [], readOnly: true),
        tool("open_audio", "Open one local audio or video file inside your home folder. Videos must contain an audio track. Replaces the previous file and discards its unexported transcript. Up to 200 MB and four hours. Tools must be installed by the user.", ["path": string], ["path"]),
        tool("start_transcription", "Start a local WhisperX CPU/int8 job and return immediately with a job ID. Poll get_status. The chosen transcription model must already be downloaded in Tools & setup. Alignment and speech-detection resources may download into the configured folder on first use.", [
            "preset": ["type": "string", "enum": ["standard", "detailed", "custom"]],
            "model": ["type": "string", "enum": TranscriptionOptions.models],
            "language": ["type": "string", "enum": TranscriptionOptions.languages.map(\.0)],
            "vad": ["type": "string", "enum": ["silero", "pyannote"]],
            "batch_size": ["type": "integer", "minimum": 1, "maximum": 32],
            "chunk_size": ["type": "integer", "minimum": 5, "maximum": 30],
            "output_format": ["type": "string", "enum": TranscriptionOutputFormat.allCases.map(\.rawValue)],
            "align": ["type": "boolean"]
        ], []),
        tool("read_transcript", "Read a page of the completed plain-text transcript. Full JSON with word timestamps is available through export_transcript. Offset and limit count Unicode characters.", [
            "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 20000]
        ], [], readOnly: true),
        tool("export_transcript", "Save one completed TXT, JSON, SRT, VTT or TSV transcript to a new absolute file path inside your home folder. Never overwrites files. Extension must match format.", [
            "format": ["type": "string", "enum": TranscriptFormat.allCases.map(\.rawValue)], "destination": string
        ], ["format", "destination"]),
        tool("check_tools", "Test installed Python, FFmpeg, FFprobe and the configured WhisperX environment. Installs nothing; setup is performed by the user in Tools.", [:], [], readOnly: true),
        tool("cancel_operation", "Request cancellation of Whisp's current transcription, export or tool check.", [:], []),
        tool("clear_temporary_data", "Discard the current unexported transcript. Keeps audio, saved exports, models and the environment. Requires an idle app.", [:], [])
    ]
    static var names: Set<String> { Set(catalog.compactMap { $0["name"] as? String }) }
    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String], readOnly: Bool = false) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": ["clear_temporary_data", "open_audio"].contains(name), "openWorldHint": name == "start_transcription"]]
    }
    static func failure(_ message: String) -> [String: Any] { ["content": [["type": "text", "text": message]], "isError": true] }
    private static func success(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": false]
    }
    static func validate(_ name: String, _ arguments: [String: Any]) throws {
        guard let schema = catalog.first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]], let required = schema["required"] as? [String],
              Set(arguments.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ arguments[$0] != nil }) else {
            throw WhispFailure(message: "Missing or unknown arguments. Check tools/list.")
        }
        for (key, value) in arguments {
            guard let field = properties[key] else { continue }
            switch field["type"] as? String {
            case "string":
                guard let text = value as? String, !text.isEmpty, text.utf8.count <= 4096 else { throw WhispFailure(message: "\(key) must be a nonempty string.") }
                if let choices = field["enum"] as? [String], !choices.contains(text) { throw WhispFailure(message: "Invalid \(key). Check tools/list.") }
            case "boolean":
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { throw WhispFailure(message: "\(key) must be true or false.") }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue, number.doubleValue <= Double(Int32.max),
                      number.intValue >= (field["minimum"] as? Int ?? 0), number.intValue <= (field["maximum"] as? Int ?? Int(Int32.max)) else {
                    throw WhispFailure(message: "\(key) must be an integer in the supported range.")
                }
            default: throw WhispFailure(message: "Unsupported argument.")
            }
        }
    }
    private static func file(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw WhispFailure(message: "Use an absolute local path.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(home + "/") else { throw WhispFailure(message: "AI file access is limited to your home folder, including resolved symbolic links.") }
        return url
    }
    static func status(_ workspace: Workspace) -> [String: Any] {
        var value: [String: Any] = ["busy": workspace.busy || workspace.testing, "activity": workspace.activity, "job_state": workspace.jobState, "tools_ready": workspace.report?.ready == true]
        if let id = workspace.jobID { value["job_id"] = id.uuidString }
        if let error = workspace.jobError { value["error"] = error }
        if let progress = workspace.progress { value["progress"] = progress }
        if let audio = workspace.audio { value["audio"] = ["path": audio.source.path, "duration_seconds": audio.duration, "bytes": audio.bytes] }
        value["models"] = workspace.models.map { ["id": $0.id, "available": $0.available, "selected": workspace.options.model == $0.id] }
        if let result = workspace.result { value["result"] = ["language": result.language, "timed_words": result.wordCount, "formats": result.files.keys.map(\.rawValue).sorted()] }
        return value
    }
    static func call(_ name: String, _ arguments: [String: Any], workspace: Workspace,
                     operationStarted: (UUID) -> Void = { _ in }) async throws -> [String: Any] {
        switch name {
        case "get_status": return success(status(workspace))
        case "open_audio":
            try await workspace.openAudio(try file(arguments["path"] as? String ?? ""), operationStarted: operationStarted)
            return success(status(workspace))
        case "start_transcription":
            try workspace.requireAIIdle()
            var options = workspace.options
            let preset = arguments["preset"] as? String ?? "standard"
            if preset == "standard" { options.apply(.standard) }
            if preset == "detailed" { options.apply(.detailed) }
            if let model = arguments["model"] as? String { options.model = model }
            if let language = arguments["language"] as? String { options.language = language }
            if let vad = arguments["vad"] as? String { options.vad = vad }
            if let batch = arguments["batch_size"] as? Int { options.batchSize = batch }
            if let chunk = arguments["chunk_size"] as? Int { options.chunkSize = chunk }
            if let align = arguments["align"] as? Bool { options.align = align }
            if let format = arguments["output_format"] as? String, let value = TranscriptionOutputFormat(rawValue: format) { options.outputFormat = value }
            try options.validate()
            guard let storage = workspace.storage else { throw WhispFailure(message: "Choose a setup folder and download a transcription model in Tools & setup first.") }
            _ = try ModelCatalog.requireAvailable(options.model, storage: storage)
            workspace.options = options; workspace.preset = .custom
            let id = try workspace.startTranscription()
            if let operation = workspace.operationID { operationStarted(operation) }
            return success(["job_id": id.uuidString, "job_state": "running", "next": "Poll get_status; export once completed."])
        case "read_transcript":
            guard let result = workspace.result else { throw WhispFailure(message: "No completed transcript. Start transcription and poll get_status.") }
            let offset = arguments["offset"] as? Int ?? 0
            let limit = arguments["limit"] as? Int ?? 8000
            let count = result.text.count
            guard offset <= count else { throw WhispFailure(message: "Offset is past the end of the transcript.") }
            let text = String(result.text.dropFirst(offset).prefix(limit))
            return success(["text": text, "offset": offset, "next_offset": offset + text.count, "total_characters": count, "has_more": offset + text.count < count, "preview_truncated": result.previewTruncated, "full_transcript": "Use export_transcript for the complete file."])
        case "export_transcript":
            guard let format = TranscriptFormat(rawValue: arguments["format"] as? String ?? "") else { throw WhispFailure(message: "Invalid export format.") }
            let receipt = try await workspace.export(format, to: try file(arguments["destination"] as? String ?? ""), operationStarted: operationStarted)
            return success(["files": receipt.files.map(\.path)])
        case "check_tools":
            let report = try await workspace.checkToolsForAI(operationStarted: operationStarted)
            return success(["ready": report.ready, "python": report.python ?? "", "ffmpeg": report.ffmpeg ?? "", "ffprobe": report.ffprobe ?? "", "whisperx": report.whisperVersion ?? "", "message": report.message])
        case "cancel_operation":
            let running = workspace.busy || workspace.testing
            workspace.cancelOperation()
            return success(["cancellation_requested": running])
        case "clear_temporary_data":
            try workspace.requireAIIdle(); workspace.clearTemporaryData()
            return success(status(workspace))
        default: throw WhispFailure(message: "Unknown tool.")
        }
    }
}
