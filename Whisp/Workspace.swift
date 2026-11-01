import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class Workspace {
    static let shared = Workspace()
    private(set) var storage: Storage?
    private(set) var report: ToolReport?
    private(set) var audio: AudioAsset?
    private(set) var result: TranscriptResult?
    private(set) var busy = false
    private(set) var testing = false
    private(set) var cancelling = false
    private(set) var activity = "Ready when you are"
    private(set) var progress: Double?
    private(set) var log = ""
    let liveLogs = LiveLogs()
    @ObservationIgnored private var operationLog: SessionLog?
    private(set) var models: [ModelAvailability] = []
    private(set) var downloadingModel: String?
    private(set) var modelDownloadProgress: Double?
    private(set) var modelDownloadBytes: Int64 = 0
    private(set) var modelDownloadTotal: Int64 = 0
    private(set) var refreshingModels = false
    private var modelRefreshID = UUID()
    private(set) var jobID: UUID?
    private(set) var jobState = "idle"
    private(set) var jobError: String?
    private(set) var startedAt: Date?
    private(set) var operationID: UUID?
    private(set) var isClosed = false
    var options: TranscriptionOptions { didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options") } } }
    var preset: TranscriptionPreset = .standard
    var selectedFormat: TranscriptFormat = .txt { didSet { UserDefaults.standard.set(selectedFormat.rawValue, forKey: "exportFormat") } }
    var showTools = false
    var error: String?
    var notice: String?
    var exportReceipt: ExportReceipt?
    var pythonPath: String { didSet { UserDefaults.standard.set(pythonPath, forKey: "pythonPath"); invalidateReport() } }
    var toolsFolder: String { didSet { UserDefaults.standard.set(toolsFolder, forKey: "toolsFolder"); invalidateReport() } }
    private var cancellation: OperationCancellation?
    private var ownedJobs: [URL] = []
    private var progressBuffer = ""

    init() {
        let defaults = UserDefaults.standard
        pythonPath = defaults.string(forKey: "pythonPath") ?? ""
        toolsFolder = defaults.string(forKey: "toolsFolder") ?? ""
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(TranscriptionOptions.self, from: $0) } ?? TranscriptionOptions()
        selectedFormat = TranscriptFormat(rawValue: defaults.string(forKey: "exportFormat") ?? "txt") ?? .txt
        if let data = defaults.data(forKey: "toolReport") { report = try? JSONDecoder().decode(ToolReport.self, from: data) }
        if let path = defaults.string(forKey: "setupRoot") {
            let candidate = Storage(root: URL(fileURLWithPath: path, isDirectory: true))
            do { try candidate.prepare(); storage = candidate }
            catch { notice = "Your setup folder is unavailable. Choose it again in Tools."; report = nil }
        }
        if options.model == "large-v3", options.vad == "silero", options.batchSize == 1, options.chunkSize == 15 { preset = .detailed }
        else if options.model != "small" || options.vad != "pyannote" || options.batchSize != 8 || options.chunkSize != 30 { preset = .custom }
    }

    func activate() { isClosed = false; MCPAccess.shared.activate(self); Task { await refreshModels() } }
    func requireAIIdle() throws {
        guard !isClosed else { throw WhispFailure(message: "Open the Whisp window first.") }
        guard !busy && !testing else { throw WhispFailure(message: "Whisp is busy. Wait or cancel the current operation.") }
    }
    private func invalidateReport() {
        report = nil
        UserDefaults.standard.removeObject(forKey: "toolReport")
    }
    private func persistReport(_ value: ToolReport) {
        report = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "toolReport") }
    }
    private func begin(_ title: String, test: Bool = false) throws -> OperationCancellation {
        try requireAIIdle()
        busy = !test; testing = test; cancelling = false; activity = title
        operationID = UUID(); startedAt = Date(); progress = nil; progressBuffer = ""; log = ""; error = nil; notice = nil
        operationLog = liveLogs.capture(in: storage)
        liveLogs.note(title)
        let token = OperationCancellation(); cancellation = token
        return token
    }
    private func finish() {
        liveLogs.note("Operation finished: \(activity)")
        operationLog = nil
        busy = false; testing = false; cancelling = false; cancellation = nil; operationID = nil; startedAt = nil
        normalizeModelSelection()
        if isClosed { activity = "Ready when you are" }
    }

    func chooseFolder() {
        guard !busy && !testing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Whisp will create a Whisp Data folder here for its environment, models and cache."
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do { try setFolder(parent) } catch { self.error = error.localizedDescription }
    }
    func setFolder(_ parent: URL) throws {
        try requireAIIdle()
        let next = try Storage.choose(parent)
        clearTemporaryData()
        storage = next
        models = []
        Task { await refreshModels() }
        UserDefaults.standard.set(next.root.path, forKey: "setupRoot")
        invalidateReport()
        notice = "Setup folder saved. Test tools, then install the environment."
    }

    @discardableResult
    func checkToolsForAI(operationStarted: (UUID) -> Void = { _ in }) async throws -> ToolReport {
        let token = try begin("Testing your tools…", test: true)
        if let operationID { operationStarted(operationID) }
        defer { finish() }
        do {
            let value = try await Backend.shared.check(storage: storage, pythonPath: pythonPath, toolsFolder: toolsFolder, cancellation: token, sessionLog: operationLog, progress: updates(for: operationID))
            try token.check()
            guard !isClosed else { throw CancellationError() }
            persistReport(value)
            await refreshModels()
            activity = value.ready ? "Tools are ready" : "Setup needs attention"
            return value
        } catch { activity = token.isCancelled ? "Tool check cancelled" : "Tool check failed"; throw error }
    }
    func testTools() async {
        do { _ = try await checkToolsForAI() } catch { showFailure(error) }
    }

    func install() async {
        do {
            try requireAIIdle()
            guard let storage else { throw WhispFailure(message: "Choose a setup folder first.") }
            let checked = try await checkToolsForAI()
            guard let python = checked.python, checked.ffmpeg != nil, checked.ffprobe != nil else {
                throw WhispFailure(message: "Install compatible Python and FFmpeg yourself, then test again. \(checked.message)")
            }
            let token = try begin("Creating your environment…")
            defer { finish() }
            let id = operationID
            do {
                try await Backend.shared.install(storage: storage, python: python, ffmpeg: checked.ffmpeg, cancellation: token, sessionLog: operationLog, progress: updates(for: id))
                activity = "Checking the new environment…"
                let value = try await Backend.shared.check(storage: storage, pythonPath: pythonPath, toolsFolder: toolsFolder, cancellation: token, sessionLog: operationLog, progress: updates(for: operationID))
                try token.check()
                guard !isClosed else { throw CancellationError() }
                persistReport(value)
                guard value.ready else { throw WhispFailure(message: value.message) }
                await refreshModels()
                activity = "Environment ready"; notice = "WhisperX is installed. Download a transcription model below to get started."
            } catch {
                if !token.isCancelled { invalidateReport() }
                throw error
            }
        } catch { showFailure(error) }
    }

    func pickAudio() {
        guard !busy && !testing else { return }
        let panel = MediaInput.makePicker()
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { try await openAudio(url) } catch { showFailure(error) } }
        }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy && !testing else { notice = "Wait for the current operation to finish, or cancel it first."; return false }
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            notice = "Drop one local audio or video file at a time."
            return false
        }
        Task {
            do { try await openAudio(try await MediaInput.droppedFile(from: provider)) }
            catch { showFailure(error) }
        }
        return true
    }
    func openAudio(_ url: URL, operationStarted: (UUID) -> Void = { _ in }) async throws {
        try requireAIIdle()
        try MediaInput.validateFile(url)
        // Recheck tools so saved status is helpful without trusting stale paths.
        let checked = try await checkToolsForAI(operationStarted: operationStarted)
        guard let ffprobe = checked.ffprobe else { showTools = true; throw WhispFailure(message: "FFprobe is required to read audio. Install FFmpeg and test tools.") }
        let token = try begin("Reading file…")
        if let operationID { operationStarted(operationID) }
        defer { finish() }
        let item = try await Backend.shared.inspect(url, ffprobe: ffprobe, cancellation: token, sessionLog: operationLog, progress: updates(for: operationID))
        try token.check()
        guard !isClosed else { throw CancellationError() }
        clearResults()
        audio = item; jobState = "idle"; jobID = nil; jobError = nil
        activity = "Ready to transcribe"
    }

    func applyPreset(_ value: TranscriptionPreset) { preset = value; options.apply(value) }

    @discardableResult
    func startTranscription() throws -> UUID {
        try requireAIIdle()
        guard let audio, let storage else { showTools = true; throw WhispFailure(message: "Choose a setup folder and an audio or video file first.") }
        try MediaInput.validateFile(audio.source)
        try options.validate()
        _ = try ModelCatalog.requireAvailable(options.model, storage: storage)
        guard report?.ready == true, FileManager.default.isExecutableFile(atPath: storage.python.path) else {
            showTools = true; throw WhispFailure(message: "Test tools and install the environment before transcribing.")
        }
        let output = try storage.jobDirectory()
        let token = try begin("Checking transcription tools…")
        ownedJobs.append(output)
        let id = UUID(); jobID = id; jobState = "running"; jobError = nil
        let operation = operationID
        let selectedOptions = options
        liveLogs.note("Model: \(options.model) · Language: \(options.language) · CPU/int8 · VAD: \(options.vad) · Batch: \(options.batchSize) · Chunk: \(options.chunkSize)s · Alignment: \(options.align) · Output: \(options.outputFormat.title)")
        Task {
            defer { finish() }
            do {
                let checked = try await Backend.shared.check(storage: storage, pythonPath: pythonPath, toolsFolder: toolsFolder, cancellation: token, sessionLog: operationLog, progress: updates(for: operationID))
                try token.check()
                guard checked.ready, let ffmpeg = checked.ffmpeg else { persistReport(checked); throw WhispFailure(message: checked.message) }
                persistReport(checked)
                let updated = try await Backend.shared.transcribe(audio, storage: storage, output: output, options: selectedOptions,
                    ffmpeg: ffmpeg, cancellation: token, sessionLog: operationLog, progress: updates(for: operation))
                try token.check()
                guard !isClosed else { throw CancellationError() }
                // Keep the previous result until its replacement has succeeded.
                clearResults(except: output)
                result = updated; jobState = "completed"; activity = "Transcription complete"; progress = 1
                if updated.files[selectedFormat] == nil,
                   let first = TranscriptFormat.allCases.first(where: { updated.files[$0] != nil }) {
                    selectedFormat = first
                }
                notice = "Your transcript is ready. Save it before closing this window."
            } catch {
                storage.removeJob(output); ownedJobs.removeAll { $0 == output }
                jobState = token.isCancelled || error is CancellationError ? "cancelled" : "failed"
                jobError = jobState == "failed" ? error.localizedDescription : nil
                showFailure(error)
            }
        }
        return id
    }

    private func updates(for id: UUID?) -> @Sendable (String) -> Void {
        { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id, !self.isClosed, !self.cancelling else { return }
                self.receive(chunk)
            }
        }
    }
    private func receive(_ chunk: String) {
        log += chunk
        if log.count > 18_000 { log = String(log.suffix(18_000)) }
        progressBuffer += chunk.replacingOccurrences(of: "\r", with: "\n")
        let lines = progressBuffer.components(separatedBy: "\n")
        progressBuffer = String((lines.last ?? "").suffix(4096))
        for line in lines.dropLast() {
            if line.hasPrefix("WHISP_EVENT "), let data = line.dropFirst(12).data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let stage = event["stage"] as? String {
                if !["Complete", "Failed"].contains(stage) { activity = stage; progress = nil }
                if let downloadingModel, event["model"] as? String == downloadingModel {
                    modelDownloadProgress = event["progress"] as? Double
                    modelDownloadBytes = (event["downloaded"] as? NSNumber)?.int64Value ?? 0
                    modelDownloadTotal = (event["total"] as? NSNumber)?.int64Value ?? 0
                }
            } else if line.localizedCaseInsensitiveContains("Performing transcription") {
                activity = "Transcribing audio…"; progress = nil
            } else if line.localizedCaseInsensitiveContains("Performing alignment") {
                activity = "Aligning word timestamps…"; progress = nil
            } else if let range = line.range(of: "Progress: "), let number = line[range.upperBound...].split(separator: "%").first, let value = Double(number), (0...100).contains(value) {
                progress = min(value / 100, 0.99)
            }
        }
    }

    func save(all: Bool = false) {
        guard !busy && !testing, let result, let audio else { return }
        if all {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Save transcripts"
            if panel.runModal() == .OK, let folder = panel.url {
                let base = audio.source.deletingPathExtension().lastPathComponent
                Task { do { _ = try await exportAll(to: folder, basename: base) } catch { showFailure(error) } }
            }
        } else {
            let format = selectedFormat
            guard result.files[format] != nil else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
            panel.nameFieldStringValue = audio.source.deletingPathExtension().lastPathComponent + "." + format.rawValue
            panel.message = "Choose a new filename. Existing files are kept."
            if panel.runModal() == .OK, let destination = panel.url {
                Task { do { _ = try await export(format, to: destination) } catch { showFailure(error) } }
            }
        }
    }
    func export(_ format: TranscriptFormat, to destination: URL, operationStarted: (UUID) -> Void = { _ in }) async throws -> ExportReceipt {
        try requireAIIdle()
        guard let source = result?.files[format], destination.pathExtension.lowercased() == format.rawValue else {
            throw WhispFailure(message: "Choose an available format and a destination ending in .\(format.rawValue).")
        }
        return try await writeExports([(source, destination)], operationStarted: operationStarted)
    }
    private func exportAll(to folder: URL, basename: String) async throws -> ExportReceipt {
        try requireAIIdle()
        guard let result else { throw WhispFailure(message: "Transcribe audio first.") }
        let files = TranscriptFormat.allCases.compactMap { format -> (URL, URL)? in
            guard let source = result.files[format] else { return nil }
            return (source, folder.appendingPathComponent(basename).appendingPathExtension(format.rawValue))
        }
        return try await writeExports(files)
    }
    private func writeExports(_ files: [(URL, URL)], operationStarted: (UUID) -> Void = { _ in }) async throws -> ExportReceipt {
        let token = try begin("Saving transcript…")
        if let operationID { operationStarted(operationID) }
        defer { finish() }
        let receipt = try await Backend.shared.export(files, cancellation: token)
        try token.check()
        if !isClosed { exportReceipt = receipt; activity = "Export complete" }
        return receipt
    }
    func modelAvailable(_ model: String) -> Bool { models.contains { $0.id == model && $0.available } }

    func refreshModels() async {
        let id = UUID(); modelRefreshID = id; refreshingModels = true
        let root = storage
        let inventory = await Backend.shared.modelInventory(storage: root)
        guard id == modelRefreshID, storage?.root.path == root?.root.path, !isClosed else {
            if id == modelRefreshID { refreshingModels = false }
            return
        }
        models = inventory
        refreshingModels = false
        if !busy && !testing { normalizeModelSelection() }
    }

    private func normalizeModelSelection() {
        if !modelAvailable(options.model) {
            options.model = models.first(where: \.available)?.id ?? ""
            preset = .custom
        }
    }

    func selectModel(_ model: String) {
        guard !busy && !testing, modelAvailable(model) else { return }
        options.model = model; preset = .custom
    }

    func downloadModel(_ model: String) async {
        do {
            guard let storage else { throw WhispFailure(message: "Choose a setup folder first.") }
            guard report?.environmentWorks == true else { throw WhispFailure(message: "Install and test the WhisperX environment first.") }
            let token = try begin("Preparing model download…")
            downloadingModel = model; modelDownloadProgress = nil; modelDownloadBytes = 0; modelDownloadTotal = 0
            defer { downloadingModel = nil; finish() }
            do {
                try await Backend.shared.downloadModel(model, storage: storage, cancellation: token, sessionLog: operationLog, progress: updates(for: operationID))
                try token.check()
                guard !isClosed else { throw CancellationError() }
                options.model = model; preset = .custom
                activity = "Model available"; notice = "\(model) is downloaded and selected."
            } catch { showFailure(error) }
            await refreshModels()
        } catch { showFailure(error) }
    }

    func deleteModel(_ model: String) async {
        do {
            guard let storage else { return }
            _ = try begin("Deleting \(model)…")
            defer { finish() }
            try await Backend.shared.removeModel(model, storage: storage)
            if options.model == model { options.model = ""; preset = .custom }
            activity = "Model deleted"; notice = "\(model) removed. Your environment and other models are kept."
            await refreshModels()
        } catch { showFailure(error) }
    }

    func cancelOperation(ifOwnedBy id: UUID? = nil) {
        if let id, operationID != id { return }
        guard busy || testing else { return }
        cancelling = true; activity = "Cancelling…"; cancellation?.cancel()
    }
    func clearTemporaryData() {
        guard !busy && !testing else { return }
        clearResults(); liveLogs.clear(); jobID = nil; jobState = "idle"; jobError = nil; log = ""; progress = nil
        notice = "Temporary transcripts and logs cleared. Your audio, saved exports and installed models are kept."
        activity = "Ready when you are"
    }
    private func clearResults(except keep: URL? = nil) {
        if let storage { for url in ownedJobs where url != keep { storage.removeJob(url) } }
        ownedJobs.removeAll { $0 != keep }
        result = nil
    }
    func removeAudio() {
        guard !busy && !testing else { return }
        clearResults(); audio = nil; exportReceipt = nil
        jobID = nil; jobState = "idle"; jobError = nil; progress = nil
        activity = "Ready when you are"
        notice = nil
    }
    func removeModels() async {
        do {
            guard let storage else { return }
            _ = try begin("Removing downloaded models…")
            defer { finish() }
            try await Backend.shared.removeModels(storage: storage)
            await refreshModels()
            notice = "Downloaded models and caches removed. The environment is kept; download the models you want in Tools & setup."
            activity = "Models removed"
        } catch { showFailure(error) }
    }
    func close() {
        guard !isClosed else { return }
        isClosed = true; cancelOperation(); liveLogs.clear(); log = ""
        // Delete immediately, then again after any in-flight worker has stopped.
        let pending = ownedJobs; let currentStorage = storage
        if let currentStorage { for url in pending { currentStorage.removeJob(url) } }
        result = nil; audio = nil; ownedJobs = []; jobState = "idle"; jobID = nil
        Task { await Backend.shared.removeJobs(pending, storage: currentStorage) }
        MCPAccess.shared.detach(self)
    }
    func showFailure(_ failure: Error) {
        if failure is CancellationError || cancellation?.isCancelled == true { activity = "Cancelled"; if !isClosed { liveLogs.note("Cancelled") }; return }
        guard !isClosed else { return }
        liveLogs.note("Error: \(failure.localizedDescription)")
        error = failure.localizedDescription; activity = "Needs attention"
    }
}

extension Backend {
    func removeJobs(_ jobs: [URL], storage: Storage?) {
        guard let storage else { return }
        for url in jobs { storage.removeJob(url) }
    }
}
