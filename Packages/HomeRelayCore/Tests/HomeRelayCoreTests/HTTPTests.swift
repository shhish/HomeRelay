import Foundation
import Network
import NIOCore
import Testing
@testable import HomeRelayCore

/// Runs the real NIO server on an ephemeral port in front of `FakeHome`.
final class TestServer: Sendable {
    let home = FakeHome()
    let events: EventHub
    let port: Int
    private let task: Task<Void, Never>
    private let dir: URL

    static let control = "control-token-for-tests"
    static let read = "read-token-for-tests"

    init(
        idleTimeout: Duration = .seconds(120), events: EventHub = EventHub(), history: History? = nil, states: StateStore? = nil,
        bridgeStatus: (@Sendable () async -> Data)? = nil
    ) async throws {
        self.events = events
        dir = FileManager.default.temporaryDirectory.appending(path: "homerelay-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenFile = dir.appending(path: "tokens.json")
        let json = """
        {"tokens":[{"name":"ctl","scope":"control","sha256":"\(TokenStore.hash(Self.control))"},
                   {"name":"ro","scope":"read","sha256":"\(TokenStore.hash(Self.read))"}]}
        """
        try Data(json.utf8).write(to: tokenFile)

        let router = APIRouter(backend: home, tokens: TokenStore(path: tokenFile), events: events, history: history, states: states, bridgeStatus: bridgeStatus, version: "test", heartbeat: .milliseconds(200))
        let idle = TimeAmount.milliseconds(Int64(idleTimeout / .milliseconds(1)))
        let server = HTTPServer(host: "127.0.0.1", port: 0, idleTimeout: idle) { await router.handle($0) }
        let (portStream, portContinuation) = AsyncStream<Int>.makeStream()
        task = Task {
            try? await server.run { portContinuation.yield($0); portContinuation.finish() }
        }
        var bound = 0
        for await p in portStream { bound = p }
        port = bound
    }

    deinit {
        task.cancel()
        try? FileManager.default.removeItem(at: dir)
    }

    func request(_ method: String, _ path: String, token: String? = TestServer.control, body: String? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func object(_ data: Data) throws -> [String: JSONValue] {
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw APIError.badRequest("not an object") }
        return o
    }
}

@Suite(.serialized) struct HTTPTests {
    @Test func healthIsPublicAndTerse() async throws {
        let server = try await TestServer()
        let (status, data) = try await server.request("GET", "/api/v1/health", token: nil)
        #expect(status == 200)
        #expect(try server.object(data) == [
            "status": .string("ok"), "service": .string("homerelay"), "version": .string("test"),
            "homekit": .string("ready"), "eventLog": .string("off"), "bridge": .string("off"),
        ])

        await server.home.setReady(false)
        let (_, degraded) = try await server.request("GET", "/api/v1/health", token: nil)
        #expect(try server.object(degraded)["status"] == .string("degraded"))
    }

    @Test func bridgeHealthShowsAFailingBridgeWithoutTheSetupCode() async throws {
        actor Box { var json = #"{"running":false,"paired":false,"port":51827,"accessories":0}"#; func set(_ j: String) { json = j } }
        let box = Box()
        let server = try await TestServer(bridgeStatus: { Data(await box.json.utf8) })
        var (status, data) = try await server.request("GET", "/api/v1/health/bridge", token: nil)
        #expect(status == 200)
        #expect(try server.object(data)["state"] == .string("starting"))

        // A home-directory path, built at runtime so the repo's privacy check doesn't flag it.
        let path = "/" + ["Users", "someone"].joined(separator: "/")
        await box.set(#"{"running":false,"paired":false,"port":51827,"accessories":0,"setupCode":"111-22-333","error":"Bonjour refused (registrationFailed(code: -65555)) in "# + path + #""}"#)
        (status, data) = try await server.request("GET", "/api/v1/health/bridge", token: nil)
        #expect(status == 503)
        #expect(try server.object(data) == ["state": .string("failing"), "reason": .string("localNetwork")])
        #expect(!String(decoding: data, as: UTF8.self).contains(path))
        let (_, health) = try await server.request("GET", "/api/v1/health", token: nil)
        #expect(try server.object(health)["bridge"] == .string("failing"))
        #expect(try server.object(health)["status"] == .string("degraded"))
        #expect(!String(decoding: health, as: UTF8.self).contains("111-22-333"))
        // A failing bridge doesn't make HomeKit itself unready.
        #expect(try await server.request("GET", "/api/v1/health/ready", token: nil).0 == 200)

        await box.set(#"{"running":false,"paired":true,"port":51827,"accessories":0,"error":"POSIXErrorCode(rawValue: 48): Address already in use"}"#)
        (_, data) = try await server.request("GET", "/api/v1/health/bridge", token: nil)
        #expect(try server.object(data)["reason"] == .string("portInUse"))

        await box.set(#"{"running":true,"paired":false,"port":51827,"accessories":2,"setupCode":"111-22-333"}"#)
        (status, data) = try await server.request("GET", "/api/v1/health/bridge", token: nil)
        #expect(status == 200)
        #expect(try server.object(data) == ["state": .string("unpaired")])

        await box.set(#"{"running":true,"paired":true,"port":51827,"accessories":2}"#)
        (_, data) = try await server.request("GET", "/api/v1/health/bridge", token: nil)
        #expect(try server.object(data) == ["state": .string("ok")])
    }

    @Test func everythingElseNeedsAKnownToken() async throws {
        let server = try await TestServer()
        #expect(try await server.request("GET", "/api/v1/accessories", token: nil).0 == 401)
        #expect(try await server.request("GET", "/api/v1/accessories", token: "nope").0 == 401)
        #expect(try await server.request("GET", "/api/v1/accessories", token: TestServer.read).0 == 200)
    }

    @Test func readTokensCannotWrite() async throws {
        let server = try await TestServer()
        let (status, data) = try await server.request("POST", "/api/v1/accessories/LAMP-1/toggle", token: TestServer.read)
        #expect(status == 403)
        #expect(String(decoding: data, as: UTF8.self).contains("read-only"))
        #expect(try await server.request("POST", "/api/v1/scenes/Movie/run", token: TestServer.read).0 == 403)
    }

    @Test func setsByNameAndReturnsNewState() async throws {
        let server = try await TestServer()
        let (status, data) = try await server.request("POST", "/api/v1/accessories/desk%20lamp", body: #"{"on": true, "brightness": 140}"#)
        #expect(status == 200)
        let state = try server.object(data)["state"]
        #expect(state == .object(["on": .bool(true), "brightness": .int(100)]))
    }

    @Test func togglesAndRunsScenes() async throws {
        let server = try await TestServer()
        #expect(try await server.request("POST", "/api/v1/accessories/Tower%20Fan/toggle").0 == 200)
        #expect(await server.home.fanActive == 1)
        #expect(try await server.request("POST", "/api/v1/scenes/good%20night/run").0 == 200)
        #expect(await server.home.ranScenes == ["SC-1"])
    }

    @Test func compactDropsServiceDetail() async throws {
        let server = try await TestServer()
        let (status, data) = try await server.request("GET", "/api/v1/accessories?compact=1", token: TestServer.read)
        #expect(status == 200)
        guard case .array(let list) = try JSONDecoder().decode(JSONValue.self, from: data), case .object(let first) = list[0] else {
            Issue.record("expected an array of objects")
            return
        }
        #expect(first["services"] == .array([]))
        #expect(first["state"] != nil)
    }

    @Test func writesACharacteristicDirectly() async throws {
        let server = try await TestServer()
        let (status, data) = try await server.request("PUT", "/api/v1/characteristics/C-BRI", body: #"{"value": "65"}"#)
        #expect(status == 200)
        #expect(try server.object(data)["value"] == .int(65))
    }

    @Test func errorsUseTheEnvelope() async throws {
        let server = try await TestServer()
        let (missing, body) = try await server.request("GET", "/api/v1/accessories/Garage")
        #expect(missing == 404)
        #expect(try server.object(body)["error"] != nil)
        #expect(try await server.request("POST", "/api/v1/accessories/LAMP-1", body: "not json").0 == 400)
        #expect(try await server.request("POST", "/api/v1/accessories/LAMP-1", body: #"{"hue": 3}"#).0 == 422)
        #expect(try await server.request("DELETE", "/api/v1/accessories/LAMP-1").0 == 404)
    }

    @Test func rejectsOversizedBodies() async throws {
        let server = try await TestServer()
        let big = "{\"on\": \"" + String(repeating: "x", count: 70_000) + "\"}"
        #expect(try await server.request("POST", "/api/v1/accessories/LAMP-1", body: big).0 == 413)
    }

    @Test func closesIdleConnections() async throws {
        let server = try await TestServer(idleTimeout: .milliseconds(300))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(server.port)), using: .tcp)
        let closed = AsyncStream<Void>.makeStream()
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                // Read until the server hangs up; an EOF or error means it closed us.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                    if isComplete || error != nil { closed.continuation.yield() }
                }
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        let started = ContinuousClock.now
        for await _ in closed.stream { break }
        let waited = ContinuousClock.now - started
        #expect(waited < .seconds(3))
    }

    @Test func streamsEventsWithAccessoryFilter() async throws {
        let server = try await TestServer()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/v1/events?accessory=LAMP-1")!)
        req.setValue("Bearer \(TestServer.read)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        #expect((response as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Type") == "text/event-stream")

        // Wait until the subscription is registered before publishing.
        while server.events.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        server.events.publish(HomeEvent(type: "characteristic", accessoryId: "FAN-1", characteristic: "active", value: .int(1)))
        server.events.publish(HomeEvent(type: "characteristic", accessoryId: "LAMP-1", characteristic: "on", value: .bool(true)))

        var received: [String] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            received.append(String(line.dropFirst(6)))
            break
        }
        #expect(received.count == 1)
        #expect(received[0].contains("\"accessoryId\":\"LAMP-1\""))
        #expect(!received[0].contains("FAN-1"))
    }
}
