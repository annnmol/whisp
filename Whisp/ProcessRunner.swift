import Foundation
import Darwin

nonisolated final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var cancelledGroup: Int32?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let active = lock.withLock { cancelled = true; return process }
        if let active, active.isRunning {
            if getpgid(active.processIdentifier) == active.processIdentifier { lock.withLock { cancelledGroup = active.processIdentifier } }
            Self.terminate(active, signal: SIGTERM)
        }
    }
    func track(_ active: Process) {
        let stopped = lock.withLock { process = active; return cancelled }
        if stopped && active.isRunning { Self.terminate(active, signal: SIGTERM) }
    }
    func killCancelledChildren() {
        if let group = lock.withLock({ cancelledGroup }) { kill(-group, SIGKILL) }
    }
    func untrack() { lock.withLock { process = nil } }
    func check() throws { if isCancelled { throw CancellationError() } }
    static func terminate(_ process: Process, signal: Int32) {
        let pid = process.processIdentifier
        // The Python worker creates its own process group, including pip/FFmpeg.
        if getpgid(pid) == pid { kill(-pid, signal) }
        else { kill(pid, signal) }
    }
}

nonisolated enum ProcessRunner {
    /// Poll a disk log off the main thread. Bound both the log and UI updates;
    /// inherited child handles cannot block cancellation or completion.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    directory: URL? = nil, log: URL, timeout: TimeInterval,
                    cancellation: OperationCancellation, sessionLog: SessionLog? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> String {
        try cancellation.check()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log)
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? writer.close(); try? reader.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = writer
        sessionLog?.note("Running \(executable)")
        do { try process.run() }
        catch { sessionLog?.note("Could not start tool: \(error.localizedDescription)"); throw error }
        cancellation.track(process)
        defer { cancellation.untrack() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stoppedAt: TimeInterval?
        var stoppedGroup: Int32?
        var reason: String?
        var tail = Data()
        var lastRead = 0.0
        var bytesRead: UInt64 = 0
        var decoder = LogTextDecoder()
        func consume() {
            guard let data = try? reader.read(upToCount: 262_144), !data.isEmpty else { return }
            bytesRead += UInt64(data.count)
            tail.append(data)
            if tail.count > 262_144 { tail.removeFirst(tail.count - 262_144) }
            sessionLog?.append(data)
            let decoded = decoder.decode(data)
            if !decoded.isEmpty { progress(decoded) }
        }
        while process.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRead > 0.25 { consume(); lastRead = now }
            if stoppedAt == nil && (cancellation.isCancelled || now >= deadline || bytesRead > 33_554_432) {
                reason = cancellation.isCancelled ? nil : (now >= deadline ? "The operation reached its time limit. You can retry." : "The tool produced too much output. Check the selected installation.")
                stoppedAt = now
                if getpgid(process.processIdentifier) == process.processIdentifier { stoppedGroup = process.processIdentifier }
                OperationCancellation.terminate(process, signal: SIGTERM)
            }
            if let stoppedAt, now - stoppedAt > 0.6 {
                if let stoppedGroup { kill(-stoppedGroup, SIGKILL) }
                OperationCancellation.terminate(process, signal: SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        process.waitUntilExit()
        cancellation.killCancelledChildren()
        if let stoppedGroup { kill(-stoppedGroup, SIGKILL) }
        // Drain the bounded remaining tail once the writer has exited.
        for _ in 0..<130 { let before = bytesRead; consume(); if bytesRead == before { break } }
        let remaining = decoder.decode(Data(), final: true)
        if !remaining.isEmpty { progress(remaining) }
        sessionLog?.note(cancellation.isCancelled ? "Tool cancelled" : reason ?? "Tool exited with status \(process.terminationStatus)")
        try cancellation.check()
        if let reason { throw WhispFailure(message: reason) }
        let output = String(decoding: tail, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let lines = output.components(separatedBy: .newlines)
            if let line = lines.last(where: { $0.hasPrefix("WHISP_EVENT ") }),
               let data = line.dropFirst(12).data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               event["stage"] as? String == "Failed", let detail = event["detail"] as? String {
                let installErrors = lines.filter { $0.hasPrefix("ERROR:") }.suffix(3).joined(separator: "\n")
                throw WhispFailure(message: String((detail + (installErrors.isEmpty ? "" : "\n" + installErrors)).prefix(3000)))
            }
            throw WhispFailure(message: output.isEmpty ? "The tool exited with status \(process.terminationStatus)." : String(output.suffix(3000)))
        }
        return output
    }
}
