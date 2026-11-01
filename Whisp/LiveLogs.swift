import Foundation
import Observation
import Darwin

/// A private session file, separate from job files which are removed on failure.
/// Its lock protects file writes from the background process runner and UI reads.
nonisolated final class SessionLog: @unchecked Sendable {
    static let maximumBytes = 67_108_864
    static var fallback: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Whisp-Logs", isDirectory: true) }
    let id = UUID()
    let url: URL
    private let directory: URL
    private let storage: Storage?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var closed = false
    private var bytes = 0
    private var failure: String?
    private var full = false
    private let changed: @Sendable () -> Void

    init(storage: Storage?, changed: @escaping @Sendable () -> Void) throws {
        self.storage = storage
        self.changed = changed
        if let storage { directory = try storage.jobDirectory() }
        else {
            directory = Self.fallback.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        url = directory.appendingPathComponent("session.log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WhispFailure(message: "Could not create the live log file.")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    var state: (bytes: Int, error: String?) { lock.withLock { (bytes, failure) } }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let wrote = lock.withLock {
            guard !closed, !full, failure == nil, let handle else { return false }
            do {
                let available = max(0, Self.maximumBytes - bytes)
                let part = data.prefix(available)
                try handle.write(contentsOf: part)
                bytes += part.count
                if part.count < data.count {
                    full = true
                    let message = "The session log reached 64 MB. Clear logs when idle to start a new recording."
                    failure = message
                    let notice = Data("\n[Whisp] \(message)\n".utf8)
                    try handle.write(contentsOf: notice); bytes += notice.count
                }
            } catch { failure = "Could not write live logs: \(error.localizedDescription)" }
            return true
        }
        if wrote { changed() }
    }

    func note(_ message: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: false))
        append(Data("\n[\(stamp)] \(message)\n".utf8))
    }

    func read(from offset: UInt64 = 0, maximum: Int? = nil) throws -> Data {
        try lock.withLock {
            guard !closed else { return Data() }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            try reader.seek(toOffset: offset)
            if let maximum { return try reader.read(upToCount: maximum) ?? Data() }
            return try reader.readToEnd() ?? Data()
        }
    }

    func fullText() throws -> String {
        var decoder = LogTextDecoder()
        return TerminalText.clean(decoder.decode(try read()))
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle?.close(); handle = nil
            if let storage { storage.removeJob(directory) }
            else { try? FileManager.default.removeItem(at: directory) }
        }
    }
    deinit { close() }

    static func clearAbandoned() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: fallback, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            guard let raw = entry.lastPathComponent.split(separator: "-").first, let pid = Int32(raw), pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: entry) }
        }
    }
}

/// Retain incomplete UTF-8 bytes between reads (important for Hindi output).
nonisolated struct LogTextDecoder {
    private var pending = Data()
    mutating func decode(_ data: Data, final: Bool = false) -> String {
        pending.append(data)
        var boundary = pending.count
        if !final, !pending.isEmpty {
            let bytes = Array(pending.suffix(4))
            var index = bytes.count - 1
            while index > 0 && bytes[index] & 0xC0 == 0x80 { index -= 1 }
            let lead = bytes[index]
            let width = lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xF8 == 0xF0 ? 4 : 1
            if bytes.count - index < width { boundary -= bytes.count - index }
        }
        let result = String(decoding: pending.prefix(boundary), as: UTF8.self)
        pending.removeFirst(boundary)
        return result
    }
}

nonisolated enum TerminalText {
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

@MainActor @Observable final class LiveLogs {
    private(set) var revision = 0
    private(set) var byteCount = 0
    private(set) var error: String?
    @ObservationIgnored private(set) var file: SessionLog?
    @ObservationIgnored private var generation = UUID()

    init() { SessionLog.clearAbandoned() }

    func capture(in storage: Storage?) -> SessionLog? {
        if let file { return file }
        let current = generation
        do {
            file = try SessionLog(storage: storage) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.refresh()
                }
            }
            error = nil
            return file
        } catch { self.error = error.localizedDescription; return nil }
    }

    func note(_ message: String) { file?.note(message); refresh() }
    private func refresh() {
        byteCount = file?.state.bytes ?? 0
        error = file?.state.error ?? error
        revision &+= 1
    }
    func clear() {
        generation = UUID()
        file?.close(); file = nil
        byteCount = 0; error = nil; revision &+= 1
    }
}
