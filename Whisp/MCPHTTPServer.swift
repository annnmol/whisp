import Foundation
import Network

nonisolated struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct MCPHTTPResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
}

/// A bounded, loopback-only HTTP transport. Each connection serves one request;
/// MCP sessions persist across connections using the MCP-Session-Id header.
nonisolated final class MCPHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (MCPHTTPRequest, @escaping @Sendable (MCPHTTPResponse) -> Void) -> Void
    private let queue = DispatchQueue(label: "com.whisp.mcp.http", qos: .userInitiated)
    private let listener: NWListener
    private let handler: Handler
    private let state: @Sendable (Bool, String?) -> Void
    // Access to the connection table and every Client is confined to queue.
    private var clients: [UUID: Client] = [:]
    private var stopped = false

    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var headerEnd: Int?
        var length = 0
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var responding = false
        var timer: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16, state: @escaping @Sendable (Bool, String?) -> Void, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.state = state
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] update in
            guard let self, !self.stopped else { return }
            switch update {
            case .ready: self.state(true, nil)
            case .failed(let error): self.state(false, error.localizedDescription); self.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.clients.count < 24 else { connection.cancel(); return }
            let client = Client(connection)
            self.clients[client.id] = client
            connection.stateUpdateHandler = { [weak self, weak client] update in
                guard let self, let client else { return }
                if case .failed = update { self.remove(client) }
                if case .cancelled = update { self.remove(client) }
            }
            connection.start(queue: self.queue)
            self.deadline(client, seconds: 10)
            self.receive(client)
        }
        listener.start(queue: queue)
    }

    func stop() { queue.async { [self] in finish() } }

    private func finish() {
        stopped = true
        listener.cancel()
        for client in Array(clients.values) { remove(client) }
    }

    private func deadline(_ client: Client, seconds: Double) {
        client.timer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak client] in
            if let self, let client { self.remove(client) }
        }
        client.timer = timer
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.clients[client.id] != nil else { return }
            if let data { client.buffer.append(data) }
            if self.parse(client) { return }
            if complete || error != nil { self.remove(client) }
            else { self.receive(client) }
        }
    }

    /// Reject ambiguous framing instead of supporting chunking or pipelining.
    private func parse(_ client: Client) -> Bool {
        if client.headerEnd == nil {
            guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if client.buffer.count > 16_384 { send(MCPHTTPResponse(status: 431), to: client); return true }
                return false
            }
            guard end.upperBound <= 16_384,
                  let header = String(data: client.buffer[..<end.lowerBound], encoding: .utf8) else {
                send(MCPHTTPResponse(status: 400), to: client); return true
            }
            let lines = header.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1" else {
                send(MCPHTTPResponse(status: 400), to: client); return true
            }
            client.method = String(first[0]); client.path = String(first[1])
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                    send(MCPHTTPResponse(status: 400), to: client); return true
                }
                let key = line[..<colon].lowercased()
                guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      client.headers[key] == nil else {
                    send(MCPHTTPResponse(status: 400), to: client); return true
                }
                client.headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard client.headers["transfer-encoding"] == nil else {
                send(MCPHTTPResponse(status: 400), to: client); return true
            }
            let rawLength = client.headers["content-length"] ?? "0"
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(rawLength), length <= 65_536 else {
                send(MCPHTTPResponse(status: 413), to: client); return true
            }
            client.length = length
            client.headerEnd = end.upperBound
        }
        guard let start = client.headerEnd else { return false }
        guard client.buffer.count <= start + client.length else {
            send(MCPHTTPResponse(status: 400), to: client); return true
        }
        guard client.buffer.count == start + client.length else { return false }
        client.responding = true
        deadline(client, seconds: 120)
        let request = MCPHTTPRequest(method: client.method, path: client.path, headers: client.headers,
                                     body: Data(client.buffer[start...]))
        client.buffer = Data()
        handler(request) { [weak self, weak client] response in
            guard let self, let client else { return }
            self.queue.async { [self, client] in
                guard self.clients[client.id] != nil else { return }
                self.send(response, to: client)
            }
        }
        return true
    }

    private func send(_ response: MCPHTTPResponse, to client: Client) {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 413: "Content Too Large",
                       415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n"
        header += "Content-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (key, value) in response.headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var data = Data(header.utf8); data.append(response.body)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] _ in
            if let self, let client { self.remove(client) }
        })
    }

    private func remove(_ client: Client) {
        clients.removeValue(forKey: client.id)
        client.timer?.cancel()
        client.connection.cancel()
    }
}
