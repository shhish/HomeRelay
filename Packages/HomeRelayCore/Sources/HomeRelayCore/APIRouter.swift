import Foundation

/// Maps `/api/v1/...` requests onto a `HomeBackend`. See docs/API.md.
public struct APIRouter: Sendable {
    public let backend: any HomeBackend
    public let tokens: TokenStore
    public let events: EventHub
    /// Long-term history and recent-window summaries; nil without an event log.
    public let history: History?
    public let version: String
    public let heartbeat: Duration
    /// Successful reads are frequent (an ESP32 may poll), so they are only
    /// logged when this is set. Writes and errors are always logged.
    public let logReads: Bool
    /// Receives one line per logged request, safe to store (no token values).
    public let log: @Sendable (String) -> Void

    public init(
        backend: any HomeBackend, tokens: TokenStore, events: EventHub, history: History? = nil, version: String,
        heartbeat: Duration = .seconds(15), logReads: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.tokens = tokens
        self.events = events
        self.history = history
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
                response = try await health(strict: false)
            } else if request.segments == ["api", "v1", "health", "ready"] {
                response = try await health(strict: true)
            } else if request.segments == ["api", "v1", "health", "history"] {
                response = try await historyHealth()
            } else {
                let token = try authenticate(request)
                caller = token.name
                let cause = RequestContext.validCause(request.headers["x-homerelay-cause"])
                response = try await RequestContext.$caller.withValue(token.name) {
                    try await RequestContext.$cause.withValue(cause) {
                        try await route(request, token: token)
                    }
                }
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
            let resume = q["since"] ?? request.headers["last-event-id"]
            let since: Int64?
            if let resume, !resume.isEmpty {
                guard let n = Int64(resume.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    throw APIError.badRequest("since must be a non-negative event seq")
                }
                since = n
            } else {
                since = nil
            }
            return eventStream(since: since, store: q["store"], accessoryIds: q["accessory"].map { Set($0.split(separator: ",").map(String.init)) })
        case ("GET", 2, "history") where rest[1] == "series":
            return try json(await requireHistory().series(accessory: q["accessory"], type: q["type"]))
        case ("GET", 1, "history"):
            let refs = (q["series"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !refs.isEmpty else { throw APIError.badRequest("series is required: series ids or characteristic ids, comma-separated") }
            let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            let to = try q["to"].map { try Self.parseTime($0, name: "to") } ?? now
            let from = try q["from"].map { try Self.parseTime($0, name: "from") } ?? (to - 86_400_000)
            return try json(await requireHistory().query(refs, from: from, to: to, step: q["step"] ?? "auto"))
        case ("GET", 2, "history") where rest[1] == "summary":
            guard let ref = q["series"], !ref.isEmpty else { throw APIError.badRequest("series is required") }
            let window = try Self.parseDuration(q["window"] ?? "1h")
            guard window <= .seconds(14 * 86_400) else { throw APIError.badRequest("window can be at most 14d") }
            return try json(await requireHistory().summary(ref, window: window))
        case ("GET", 2, "events") where rest[1] == "stats":
            guard let log = events.log else { throw APIError.notFound("The event log is off") }
            let hours = q["hours"].flatMap(Int.init).map { min(max($0, 1), 24 * 31) } ?? 24
            return try json(await log.stats(windowHours: hours))
        default:
            throw APIError.notFound("No route for \(request.method) \(request.path)")
        }
    }

    /// `strict` (`/health/ready`) answers 503 unless HomeKit is ready, for status-code monitors.
    private func health(strict: Bool) async throws -> HTTPResponse {
        let status = await backend.status()
        struct Health: Encodable {
            var status: String
            var service = "homerelay"
            var version: String
            var homekit: String
            var eventLog: String
            var history: History.Status?
        }
        let body = Health(
            status: status.isReady ? "ok" : "degraded", version: version, homekit: status.state,
            eventLog: events.log?.health ?? "off", history: await history?.status()
        )
        return try json(body, status: strict && !status.isReady ? 503 : 200)
    }

    /// 200 when history is healthy (or off), 503 when the disk has been away
    /// over an hour, archiving lags a day, or events were dropped in the last day.
    private func historyHealth() async throws -> HTTPResponse {
        guard let history else { return try json(["history": "off"]) }
        let status = await history.status()
        return try json(status, status: status.healthy ? 200 : 503)
    }

    private func requireHistory() throws(APIError) -> History {
        guard let history else { throw APIError.notFound("History is off: it needs the event log") }
        return history
    }

    /// Epoch milliseconds or ISO 8601.
    static func parseTime(_ raw: String, name: String) throws(APIError) -> Int64 {
        if let ms = Int64(raw) { return ms }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(raw) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        throw .badRequest("\(name) must be epoch milliseconds or ISO 8601")
    }

    /// `90s`, `15m`, `1h`, `7d`.
    static func parseDuration(_ raw: String) throws(APIError) -> Duration {
        let units: [Character: Int64] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        guard let unit = raw.last, let scale = units[unit], let n = Int64(raw.dropLast()), n > 0 else {
            throw .badRequest("window must look like 90s, 15m, 1h or 7d")
        }
        return .seconds(n * scale)
    }

    // MARK: - Events

    private func eventStream(since: Int64?, store: String?, accessoryIds: Set<String>?) -> HTTPResponse {
        let session = EventStreamSession(hub: events, since: since, store: store, accessoryIds: accessoryIds, heartbeat: heartbeat)
        return HTTPResponse(
            status: 200,
            headers: Self.corsHeaders + (events.log.map { [("X-HomeRelay-Store", $0.storeId)] } ?? []) + [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-cache"),
                ("X-Accel-Buffering", "no"),
            ],
            body: .stream(AsyncStream(unfolding: { await session.next() }))
        )
    }

    // MARK: - Helpers

    static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type, Last-Event-ID, X-HomeRelay-Cause"),
        ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS"),
        ("Access-Control-Expose-Headers", "X-HomeRelay-Store"),
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
