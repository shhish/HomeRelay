import Foundation

/// Maps `/api/v1/...` requests onto a `HomeBackend`. See docs/API.md.
public struct APIRouter: Sendable {
    public let backend: any HomeBackend
    public let tokens: TokenStore
    public let events: EventHub
    public let version: String
    public let heartbeat: Duration
    /// Successful reads are frequent (an ESP32 may poll), so they are only
    /// logged when this is set. Writes and errors are always logged.
    public let logReads: Bool
    /// Receives one line per logged request, safe to store (no token values).
    public let log: @Sendable (String) -> Void

    public init(
        backend: any HomeBackend, tokens: TokenStore, events: EventHub, version: String,
        heartbeat: Duration = .seconds(15), logReads: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.tokens = tokens
        self.events = events
        self.version = version
        self.heartbeat = heartbeat
        self.logReads = logReads
        self.log = log
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let started = ContinuousClock.now
        var caller = "-"
        let response: HTTPResponse
        do {
            if request.method == "OPTIONS" {
                response = HTTPResponse(status: 204, headers: Self.corsHeaders + [("Access-Control-Max-Age", "600")])
            } else if request.segments == ["api", "v1", "health"] {
                response = try await health()
            } else {
                let token = try authenticate(request)
                caller = token.name
                response = try await route(request, token: token)
            }
        } catch let error as APIError {
            response = Self.errorResponse(error)
        } catch {
            response = Self.errorResponse(.deviceFailed(error.localizedDescription))
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        let quiet = (request.method == "GET" || request.method == "OPTIONS") && response.status < 400 && !logReads
        if !quiet { log("\(request.method) \(request.path) \(response.status) \(ms)ms by \(caller) from \(request.remoteAddress ?? "?")") }
        return response
    }

    // MARK: - Auth

    private func authenticate(_ request: HTTPRequest) throws(APIError) -> TokenRecord {
        guard let header = request.headers["authorization"], header.lowercased().hasPrefix("bearer ") else {
            throw APIError(status: 401, code: "unauthorized", message: "Send Authorization: Bearer <token>")
        }
        let token = String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard let record = tokens.verify(token) else {
            throw APIError(status: 401, code: "unauthorized", message: "Unknown token")
        }
        return record
    }

    private func requireControl(_ token: TokenRecord) throws(APIError) {
        guard token.scope == .control else {
            throw APIError(status: 403, code: "forbidden", message: "Token '\(token.name)' is read-only")
        }
    }

    // MARK: - Routes

    private func route(_ request: HTTPRequest, token: TokenRecord) async throws -> HTTPResponse {
        guard request.segments.count >= 3, request.segments[0] == "api", request.segments[1] == "v1" else {
            throw APIError.notFound("No route for \(request.path)")
        }
        let rest = Array(request.segments.dropFirst(2))
        let q = request.query
        let home = q["home"]

        switch (request.method, rest.count, rest.first) {
        case ("GET", 1, "homes"):
            return try json(await backend.homes())
        case ("GET", 1, "snapshot"):
            var homes = try await backend.snapshot(home: home, refresh: flag(q["refresh"]))
            if flag(q["compact"]) {
                for i in homes.indices { homes[i].accessories = homes[i].accessories.map(\.compact) }
            }
            return try json(homes)
        case ("GET", 1, "rooms"):
            return try json(await backend.rooms(home: home))
        case ("GET", 1, "accessories"):
            let list = try await backend.accessories(home: home, room: q["room"], category: q["category"], refresh: flag(q["refresh"]))
            return try json(flag(q["compact"]) ? list.map(\.compact) : list)
        case ("GET", 2, "accessories"):
            let one = try await backend.accessory(rest[1], home: home, refresh: flag(q["refresh"], default: true))
            return try json(flag(q["compact"]) ? one.compact : one)
        case ("POST", 2, "accessories"), ("PATCH", 2, "accessories"):
            try requireControl(token)
            let values = try decodeObject(request.body)
            return try json(await backend.setAccessory(rest[1], home: home, values: values))
        case ("POST", 3, "accessories") where rest[2] == "toggle":
            try requireControl(token)
            return try json(await backend.toggleAccessory(rest[1], home: home))
        case ("PUT", 2, "characteristics"):
            try requireControl(token)
            let body = try decodeObject(request.body)
            guard let value = body["value"] else { throw APIError.badRequest("Body must be {\"value\": ...}") }
            return try json(await backend.writeCharacteristic(id: rest[1], value: value))
        case ("GET", 1, "scenes"):
            return try json(await backend.scenes(home: home))
        case ("POST", 3, "scenes") where rest[2] == "run":
            try requireControl(token)
            return try json(await backend.runScene(rest[1], home: home))
        case ("GET", 1, "events"):
            return await eventStream(accessoryIds: q["accessory"].map { Set($0.split(separator: ",").map(String.init)) })
        default:
            throw APIError.notFound("No route for \(request.method) \(request.path)")
        }
    }

    private func health() async throws -> HTTPResponse {
        let status = await backend.status()
        struct Health: Encodable {
            var status: String
            var service = "homerelay"
            var version: String
            var homekit: String
        }
        return try json(Health(status: status.isReady ? "ok" : "degraded", version: version, homekit: status.state))
    }

    // MARK: - Events

    private func eventStream(accessoryIds: Set<String>?) async -> HTTPResponse {
        let source = await events.subscribe()
        let heartbeat = self.heartbeat
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(512))
        continuation.yield(Data(": homerelay events\nretry: 3000\n\n".utf8))
        let pump = Task {
            for await event in source {
                if let ids = accessoryIds, !ids.contains(event.accessoryId ?? "") { continue }
                guard let payload = try? encoder.encode(event) else { continue }
                continuation.yield(Data("event: \(event.type)\ndata: ".utf8) + payload + Data("\n\n".utf8))
            }
            continuation.finish()
        }
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                continuation.yield(Data(": keepalive\n\n".utf8))
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            beat.cancel()
        }
        return HTTPResponse(
            status: 200,
            headers: Self.corsHeaders + [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-cache"),
                ("X-Accel-Buffering", "no"),
            ],
            body: .stream(stream)
        )
    }

    // MARK: - Helpers

    static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
        ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS"),
    ]

    private func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HTTPResponse(
            status: status,
            headers: Self.corsHeaders + [("Content-Type", "application/json; charset=utf-8")],
            body: .data(try encoder.encode(value))
        )
    }

    public static func errorResponse(_ error: APIError) -> HTTPResponse {
        struct Envelope: Encodable {
            struct Body: Encodable {
                var code: String
                var message: String
                var candidates: [String]?
            }
            var error: Body
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(Envelope(error: .init(code: error.code, message: error.message, candidates: error.candidates)))) ?? Data()
        var headers = corsHeaders + [("Content-Type", "application/json; charset=utf-8")]
        if error.status == 401 { headers.append(("WWW-Authenticate", "Bearer")) }
        return HTTPResponse(status: error.status, headers: headers, body: .data(body))
    }

    private func decodeObject(_ body: Data) throws(APIError) -> [String: JSONValue] {
        guard !body.isEmpty else { throw .badRequest("Expected a JSON object body") }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), case .object(let object) = value else {
            throw .badRequest("Expected a JSON object body")
        }
        return object
    }

    private func flag(_ raw: String?, default fallback: Bool = false) -> Bool {
        guard let raw else { return fallback }
        return JSONValue.string(raw).boolValue ?? (raw.isEmpty ? true : fallback)
    }
}
