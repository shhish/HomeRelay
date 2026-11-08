import Foundation

/// Maps `/api/v1/...` requests onto a `HomeBackend`. See docs/API.md.
public struct APIRouter: Sendable {
    public let backend: any HomeBackend
    public let tokens: TokenStore
    public let events: EventHub
    /// Long-term history and recent-window summaries; nil without an event log.
    public let history: History?
    /// Virtual accessories; nil when not configured.
    public let states: StateStore?
    /// The HomeKit bridge's status as JSON, when the app runs one.
    public let bridgeStatus: (@Sendable () async -> Data)?
    public let version: String
    public let heartbeat: Duration
    /// Successful reads are frequent (an ESP32 may poll), so they are only
    /// logged when this is set. Writes and errors are always logged.
    public let logReads: Bool
    /// Receives one line per logged request, safe to store (no token values).
    public let log: @Sendable (String) -> Void

    public init(
        backend: any HomeBackend, tokens: TokenStore, events: EventHub, history: History? = nil,
        states: StateStore? = nil, bridgeStatus: (@Sendable () async -> Data)? = nil, version: String,
        heartbeat: Duration = .seconds(15), logReads: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.tokens = tokens
        self.events = events
        self.history = history
        self.states = states
        self.bridgeStatus = bridgeStatus
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
            let healthRoute = request.segments == ["api", "v1", "health"]
                || (request.segments.count == 4 && request.segments.prefix(3) == ["api", "v1", "health"]
                    && ["ready", "history", "bridge"].contains(request.segments[3]))
            if healthRoute && request.method != "GET" && request.method != "OPTIONS" {
                var error = Self.errorResponse(APIError(status: 405, code: "method_not_allowed", message: "Use GET for health checks"))
                error.headers.append(("Allow", "GET"))
                response = error
            } else if request.method == "OPTIONS" {
                response = HTTPResponse(status: 204, headers: Self.corsHeaders + [("Access-Control-Max-Age", "600")])
            } else if request.segments == ["api", "v1", "health"] {
                response = try await health(strict: false)
            } else if request.segments == ["api", "v1", "health", "ready"] {
                response = try await health(strict: true)
            } else if request.segments == ["api", "v1", "health", "history"] {
                response = try await historyHealth()
            } else if request.segments == ["api", "v1", "health", "bridge"] {
                response = try await bridgeHealth()
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
                guard let n = Int64(resume.trimmingCharacters(in: .whitespaces)), n >= 0, n < Int64.max else {
                    throw APIError.badRequest("since must be a non-negative event seq below Int64.max")
                }
                since = n
            } else {
                since = nil
            }
            return eventStream(since: since, store: q["store"], accessoryIds: q["accessory"].map { Set($0.split(separator: ",").map(String.init)) })
        case ("GET", 1, "bridge"):
            // Control only: while unpaired this includes the setup code.
            try requireControl(token)
            guard let bridgeStatus else { throw APIError.notFound("The HomeKit bridge is off (HOMERELAY_BRIDGE=1 turns it on)") }
            return HTTPResponse(
                status: 200, headers: Self.corsHeaders + [("Content-Type", "application/json; charset=utf-8")],
                body: .data(await bridgeStatus())
            )
        case ("GET", 1, "states"):
            return try json(await requireStates().list())
        case ("GET", 2, "states"):
            return try json(await requireStates().get(rest[1]))
        case ("POST", 1, "states"):
            try requireControl(token)
            let body = try decodeObject(request.body)
            guard case .string(let name)? = body["name"] else { throw APIError.badRequest("Body needs a name") }
            let kind: String
            if case .string(let k)? = body["kind"] { kind = k } else { kind = "switch" }
            let reset = try Self.optionalSeconds(body["resetAfter"])
            return try json(await requireStates().create(name: name, kind: kind, resetAfter: reset ?? nil, by: token.name), status: 201)
        case ("POST", 2, "states"), ("PUT", 2, "states"), ("PATCH", 2, "states"):
            try requireControl(token)
            let body = try decodeObject(request.body)
            let store = try requireStates()
            var state = try await store.get(rest[1])
            if body["name"] != nil || body.keys.contains("resetAfter") {
                var name: String?
                if let raw = body["name"] {
                    guard case .string(let n) = raw else { throw APIError.badRequest("name must be text") }
                    name = n
                }
                let reset: Int?? = body.keys.contains("resetAfter") ? try Self.optionalSeconds(body["resetAfter"]) : nil
                state = try await store.update(state.id, name: name, resetAfter: reset)
            }
            if let raw = body["on"] {
                guard let on = raw.boolValue else { throw APIError.unprocessable("on must be true or false") }
                state = try await store.set(state.id, on: on, by: token.name, cause: RequestContext.cause)
            }
            return try json(state)
        case ("DELETE", 2, "states"):
            try requireControl(token)
            try await requireStates().delete(rest[1])
            return try json(["deleted": rest[1]])
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
            var bridge: String
            var history: History.Status?
        }
        let bridge = await bridgeState()
        let body = Health(
            status: status.isReady && bridge.state != "failing" ? "ok" : "degraded", version: version,
            homekit: status.state, eventLog: events.log?.health ?? "off", bridge: bridge.state,
            history: await history?.status()
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

    /// The HomeKit bridge as health sees it. Public, so it carries neither the
    /// setup code nor the error text (which can hold file paths); `GET /bridge` has both.
    struct BridgeHealth: Codable {
        /// `off`, `starting`, `ok` (running and paired), `unpaired` (running, waiting to
        /// be added in the Home app) or `failing` (can't start; it keeps retrying).
        var state: String
        /// While failing: `localNetwork` (Local Network access is off), `portInUse` or `other`.
        var reason: String?
    }

    func bridgeState() async -> BridgeHealth {
        guard let bridgeStatus else { return BridgeHealth(state: "off") }
        struct Status: Decodable {
            var running: Bool
            var paired: Bool
            var error: String?
        }
        guard let s = try? JSONDecoder().decode(Status.self, from: await bridgeStatus()) else {
            return BridgeHealth(state: "failing", reason: "other")
        }
        if s.running { return BridgeHealth(state: s.paired ? "ok" : "unpaired") }
        guard let error = s.error else { return BridgeHealth(state: "starting") }
        let reason = error.contains("-65555") ? "localNetwork"
            : error.contains("rawValue: 48") || error.localizedCaseInsensitiveContains("address already in use") ? "portInUse"
            : "other"
        return BridgeHealth(state: "failing", reason: reason)
    }

    /// 200 unless the bridge is failing to start, for status-code monitors.
    private func bridgeHealth() async throws -> HTTPResponse {
        let bridge = await bridgeState()
        return try json(bridge, status: bridge.state == "failing" ? 503 : 200)
    }

    private func requireStates() throws(APIError) -> StateStore {
        guard let states else { throw APIError.notFound("States are off") }
        return states
    }

    /// `resetAfter`: seconds, or null to clear. Returns nil when absent.
    static func optionalSeconds(_ raw: JSONValue?) throws(APIError) -> Int?? {
        switch raw {
        case nil: return nil
        case .null?: return .some(nil)
        case .int(let n)?: return .some(n)
        case .double(let d)? where d.isFinite && d == d.rounded():
            guard let seconds = Int(exactly: d) else { throw .badRequest("resetAfter is out of range") }
            return .some(seconds)
        default: throw .badRequest("resetAfter must be a whole number of seconds or null")
        }
    }

    private func requireHistory() throws(APIError) -> History {
        guard let history else { throw APIError.notFound("History is off: it needs the event log") }
        return history
    }

    /// Epoch milliseconds or ISO 8601.
    static func parseTime(_ raw: String, name: String) throws(APIError) -> Int64 {
        if let ms = Int64(raw) {
            guard History.supportedTimes.contains(ms) else { throw .badRequest("\(name) is outside years 1 through 9999") }
            return ms
        }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(raw),
               let ms = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()), History.supportedTimes.contains(ms) { return ms }
        }
        throw .badRequest("\(name) must be epoch milliseconds or ISO 8601")
    }

    /// `90s`, `15m`, `1h`, `7d`.
    static func parseDuration(_ raw: String) throws(APIError) -> Duration {
        let units: [Character: Int64] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        guard let unit = raw.last, let scale = units[unit], let n = Int64(raw.dropLast()), n > 0 else {
            throw .badRequest("window must look like 90s, 15m, 1h or 7d")
        }
        let (seconds, overflow) = n.multipliedReportingOverflow(by: scale)
        guard !overflow else { throw .badRequest("window is out of range") }
        return .seconds(seconds)
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
        ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"),
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
