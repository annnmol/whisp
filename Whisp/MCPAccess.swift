import AppKit
import Observation

@MainActor @Observable
final class MCPAccess {
    static let shared = MCPAccess()
    private(set) var enabled = false
    private(set) var listening = false
    private(set) var port: Int
    private(set) var token = ""
    private(set) var error: String?
    private(set) var clientCount = 0
    private(set) var activity = ""
    var address: String { "http://127.0.0.1:\(port)/mcp" }

    private var server: MCPHTTPServer?
    private var generation = UUID()
    private weak var workspace: Workspace?
    private var workspaces: [WeakWorkspace] = []
    private var sessions: [String: Session] = [:]
    private var pending: [String: Pending] = [:]
    private var jobs: [String: UUID] = [:]
    private var expiryTimer: Timer?
    private let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private struct WeakWorkspace { weak var value: Workspace? }
    private struct Session { let version: String; var touched: Date; var initialized = false }
    private struct Pending { let session: String; let workspace: Workspace; let operation: UUID? }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "mcpPort")
        port = (1024...65535).contains(saved) ? saved : 7422
        if UserDefaults.standard.bool(forKey: "mcpEnabled") { setEnabled(true) }
    }

    func activate(_ workspace: Workspace) {
        workspaces.removeAll { $0.value == nil || $0.value === workspace }
        workspaces.append(WeakWorkspace(value: workspace))
        self.workspace = workspace
    }

    func detach(_ workspace: Workspace) {
        workspaces.removeAll { $0.value == nil || $0.value === workspace }
        if self.workspace === workspace { self.workspace = workspaces.last?.value }
    }

    func setEnabled(_ value: Bool) {
        stop()
        enabled = value
        UserDefaults.standard.set(value, forKey: "mcpEnabled")
        error = nil
        guard value else { return }
        do {
            token = try MCPCredentials.loadOrCreate()
            let current = generation
            let transport = try MCPHTTPServer(port: UInt16(port), state: { [weak self] ready, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.listening = ready
                    if let failure {
                        self.error = "Could not listen on port \(self.port). Choose another port or retry. \(failure)"
                        self.stop()
                    }
                }
            }, handler: { [weak self] request, reply in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, self.enabled else {
                        reply(MCPHTTPResponse(status: 503)); return
                    }
                    reply(await self.handle(request))
                }
            })
            server = transport
            transport.start()
            expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.expireSessions() }
            }
        } catch { self.error = error.localizedDescription }
    }

    func setPort(_ value: Int) {
        guard (1024...65535).contains(value) else { error = "Choose a port between 1024 and 65535."; return }
        port = value
        UserDefaults.standard.set(value, forKey: "mcpPort")
        if enabled { setEnabled(true) }
    }

    func newToken() {
        do {
            token = try MCPCredentials.replace()
            for entry in pending.values { if let id = entry.operation { entry.workspace.cancelOperation(ifOwnedBy: id) } }
            for id in jobs.values { workspace?.cancelOperation(ifOwnedBy: id) }
            jobs.removeAll()
            sessions.removeAll()
            clientCount = 0
            error = nil
            if enabled && server == nil { setEnabled(true) }
        } catch { self.error = error.localizedDescription }
    }

    func shutdown() { stop() }

    private func stop() {
        generation = UUID()
        server?.stop(); server = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        for entry in pending.values { if let id = entry.operation { entry.workspace.cancelOperation(ifOwnedBy: id) } }
            for id in jobs.values { workspace?.cancelOperation(ifOwnedBy: id) }
        jobs.removeAll()
        pending.removeAll()
        sessions.removeAll(); clientCount = 0; listening = false; activity = ""
    }

    private func expireSessions() {
        let expired = sessions.filter { Date().timeIntervalSince($0.value.touched) > 1800 }.map(\.key)
        for id in expired where !pending.values.contains(where: { $0.session == id }) { endSession(id) }
    }

    private func endSession(_ id: String) {
        for entry in pending.values where entry.session == id { if let operation = entry.operation { entry.workspace.cancelOperation(ifOwnedBy: operation) } }
        if let operation = jobs.removeValue(forKey: id) { workspace?.cancelOperation(ifOwnedBy: operation) }
        sessions.removeValue(forKey: id)
        clientCount = sessions.count
    }

    private func json(_ object: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
        var headers = headers; headers["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func rpcError(_ id: Any, _ code: Int, _ message: String) -> MCPHTTPResponse {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func idKey(_ id: Any) -> String? {
        guard id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()),
              let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]) else { return nil }
        return data.base64EncodedString()
    }

    private func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        // Authentication applies to every method, including initialization and DELETE.
        guard MCPCredentials.matches(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return MCPHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"Whisp\""])
        }
        guard request.headers["host"] == "127.0.0.1:\(port)" || request.headers["host"] == "localhost:\(port)" else {
            return MCPHTTPResponse(status: 403)
        }
        if let origin = request.headers["origin"] {
            guard origin == "http://127.0.0.1:\(port)" || origin == "http://localhost:\(port)" else {
                return MCPHTTPResponse(status: 403)
            }
        }
        guard request.path == "/mcp" else { return MCPHTTPResponse(status: 404) }
        if request.method == "GET" { return MCPHTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"]) }
        if request.method == "DELETE" {
            guard let id = request.headers["mcp-session-id"], sessions[id] != nil else { return MCPHTTPResponse(status: 404) }
            endSession(id)
            return MCPHTTPResponse()
        }
        guard request.method == "POST" else { return MCPHTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"]) }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return MCPHTTPResponse(status: 415)
        }
        let accept = request.headers["accept"] ?? ""
        guard accept.contains("application/json"), accept.contains("text/event-stream") else { return MCPHTTPResponse(status: 406) }
        guard let raw = try? JSONSerialization.jsonObject(with: request.body) else { return rpcError(NSNull(), -32700, "Invalid JSON.") }
        guard let message = raw as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else { return rpcError(NSNull(), -32600, "Expected a JSON-RPC 2.0 request.") }
        let id = message["id"] ?? NSNull()
        let notification = message["id"] == nil
        if !notification && idKey(id) == nil { return rpcError(NSNull(), -32600, "Request IDs must be a string or number.") }
        guard message["params"] == nil || message["params"] is [String: Any] else { return rpcError(id, -32602, "Parameters must be an object.") }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            guard !notification, let version = params["protocolVersion"] as? String,
                  params["clientInfo"] is [String: Any], params["capabilities"] is [String: Any] else {
                return rpcError(id, -32602, "Initialization requires protocolVersion, capabilities and clientInfo.")
            }
            expireSessions()
            guard sessions.count < 16 else { return MCPHTTPResponse(status: 503) }
            let chosen = versions.contains(version) ? version : versions[0]
            let session = UUID().uuidString
            sessions[session] = Session(version: chosen, touched: Date())
            clientCount = sessions.count
            return json(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": chosen, "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Whisp", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
                "instructions": "Control Whisp local audio transcription. Paths must be absolute and inside the user's home folder. A user must configure the environment in Tools first. Open audio, start a transcription and poll get_status until completion, then read or export the transcript. Model downloads may occur inside the configured folder. Originals are preserved."
            ]], headers: ["MCP-Session-Id": session])
        }
        guard let session = request.headers["mcp-session-id"] else { return MCPHTTPResponse(status: 400) }
        guard let state = sessions[session] else { return MCPHTTPResponse(status: 404) }
        let version = request.headers["mcp-protocol-version"] ?? state.version
        guard versions.contains(version), version == state.version else { return MCPHTTPResponse(status: 400) }
        sessions[session]?.touched = Date()
        if notification {
            if method == "notifications/initialized" { sessions[session]?.initialized = true }
            if method == "notifications/cancelled", let requestID = params["requestId"], let key = idKey(requestID) {
                if let entry = pending[session + ":" + key] { if let operation = entry.operation { entry.workspace.cancelOperation(ifOwnedBy: operation) } }
            }
            return MCPHTTPResponse(status: 202)
        }
        if method == "ping" { return json(["jsonrpc": "2.0", "id": id, "result": [:]]) }
        guard state.initialized else { return rpcError(id, -32600, "Send notifications/initialized before using tools.") }
        if method == "tools/list" { return json(["jsonrpc": "2.0", "id": id, "result": ["tools": MCPTools.catalog]]) }
        guard method == "tools/call" else { return rpcError(id, -32601, "Method not found.") }
        guard let name = params["name"] as? String, MCPTools.names.contains(name),
              params["arguments"] == nil || params["arguments"] is [String: Any] else {
            return rpcError(id, -32602, "Unknown tool or invalid arguments.")
        }
        let key = session + ":" + (idKey(id) ?? "")
        guard pending[key] == nil else { return rpcError(id, -32600, "This request ID is already running.") }
        guard let target = workspace, !target.isClosed else {
            return json(["jsonrpc": "2.0", "id": id, "result": MCPTools.failure("Open the Whisp window first.")])
        }
        let current = generation
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            try MCPTools.validate(name, arguments)
            // Only long operations own cancellation. Read-only calls cannot cancel
            // a concurrent edit started by the user or another client.
            let ownsOperation = ["open_audio", "export_transcript", "check_tools"].contains(name)
            if ownsOperation {
                guard !target.busy, !target.testing else { throw WhispFailure(message: "Whisp is busy. Wait or cancel the current operation.") }
                pending[key] = Pending(session: session, workspace: target, operation: nil)
                activity = "AI: \(name.replacingOccurrences(of: "_", with: " "))"
            }
            defer {
                pending.removeValue(forKey: key)
                if pending.isEmpty { activity = "" }
            }
            let result = try await MCPTools.call(name, arguments, workspace: target, operationStarted: { operation in
                if ownsOperation, self.pending[key] != nil {
                    self.pending[key] = Pending(session: session, workspace: target, operation: operation)
                } else if name == "start_transcription" {
                    self.jobs[session] = operation
                }
            })
            guard current == generation, sessions[session] != nil else { return MCPHTTPResponse(status: 503) }
            return json(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            return json(["jsonrpc": "2.0", "id": id, "result": MCPTools.failure(error.localizedDescription)])
        }
    }
}
