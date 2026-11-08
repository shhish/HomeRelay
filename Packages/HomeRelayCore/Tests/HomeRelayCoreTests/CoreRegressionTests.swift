import Foundation
import Synchronization
import Testing
@testable import HomeRelayCore

struct NumericRegressionTests {
    @Test func rejectsTrappingNumericInputs() throws {
        for value in [JSONValue.double(Double(Int.max)), .double(1e100), .double(.infinity), .double(.nan)] {
            do {
                _ = try APIRouter.optionalSeconds(value)
                Issue.record("Expected resetAfter rejection")
            } catch { #expect(error.status == 400) }
        }
        for value in [JSONValue.string("nan"), .string("inf"), .double(1e100), .double(Double(Int.max))] {
            do {
                _ = try ValueCoercion.coerce(value, to: ValueSpec(format: "int"))
                Issue.record("Expected integer rejection")
            } catch { #expect(error.status == 422) }
        }
        for value in [JSONValue.string("nan"), .string("inf"), .double(.infinity)] {
            #expect(throws: APIError.self) { try ValueCoercion.coerce(value, to: ValueSpec(format: "float")) }
        }
        // Finite overshoots still obey the existing clamping contract.
        #expect(try ValueCoercion.coerce(.double(1e100), to: ValueSpec(format: "int", min: 0, max: 100)) == .int(100))
        #expect(throws: APIError.self) { try APIRouter.parseDuration("\(Int64.max)d") }
        #expect(throws: APIError.self) { try APIRouter.parseTime(String(Int64.min), name: "from") }
    }

    @Test func numericRoutesRejectOverflowWith400() async throws {
        let server = try await TestServer()
        #expect(try await server.request("GET", "/api/v1/events?since=\(Int64.max)", token: TestServer.read).0 == 400)
        #expect(try await server.request("GET", "/api/v1/history/summary?series=x&window=\(Int64.max)d", token: TestServer.read).0 == 400)
        #expect(try await server.request("GET", "/api/v1/history/summary?series=x&window=\(Int64.max)s", token: TestServer.read).0 == 400)
        #expect(try await server.request("GET", "/api/v1/history?series=x&to=\(Int64.min)", token: TestServer.read).0 == 400)
        #expect(try await server.request("POST", "/api/v1/states", body: #"{"name":"Example","resetAfter":1e100}"#).0 == 400)
    }

    @Test func internalReplayAlsoHandlesMaximumSequence() async throws {
        let log = try EventLog(path: tempLogURL())
        defer { log.close() }
        let session = EventStreamSession(hub: EventHub(log: log), since: .max, store: nil, accessoryIds: nil, heartbeat: .seconds(60))
        let frame = try #require(await session.next())
        #expect(String(decoding: frame, as: UTF8.self).contains("event: gap"))
    }
}

struct SequenceRegressionTests {
    @Test func crashAfterMoreThanOneReservationNeverReusesSeq() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var last: Int64 = 0
        do {
            let log = try EventLog(path: url)
            // No flush/close: model loss of the entire in-memory queue.
            for _ in 0..<(EventLog.uncleanSkip + 37) { last = try #require(log.append(lamp(true)).seq) }
        }
        let resumed = try EventLog(path: url)
        defer { resumed.close() }
        #expect(try #require(resumed.append(lamp(false)).seq) > last)
    }

    @Test func failedCloseLeavesSessionUncleanAndReservationIntact() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var issued: Int64 = 0
        do {
            let log = try EventLog(path: url)
            let db = try SQLiteDB(path: url.path)
            try db.exec("CREATE TRIGGER reject_events BEFORE INSERT ON events BEGIN SELECT RAISE(FAIL, 'simulated write failure'); END")
            issued = try #require(log.append(lamp(true)).seq)
            log.close()
            #expect(try db.scalar("SELECT COUNT(*) FROM sessions WHERE stopped_ms IS NULL") == 1)
            let reserved = try #require(try db.scalar("SELECT value FROM meta WHERE key = 'reserved_seq'"))
            #expect(reserved >= issued)
            #expect(log.health == "failing")
            try db.exec("DROP TRIGGER reject_events")
        }
        let resumed = try EventLog(path: url)
        defer { resumed.close() }
        #expect(try #require(resumed.append(lamp(false)).seq) > issued)
    }

    @Test func failedReservationDoesNotIssueOrStreamAnEvent() async throws {
        let log = try EventLog(path: tempLogURL())
        defer { log.close() }
        let db = try SQLiteDB(path: log.path.path)
        try db.exec("CREATE TRIGGER reject_reservation BEFORE INSERT ON meta WHEN NEW.key = 'reserved_seq' BEGIN SELECT RAISE(FAIL, 'simulated reservation failure'); END")
        let hub = EventHub(log: log)
        let subscription = hub.subscribe()
        #expect(hub.publish(lamp(true)).seq == nil)
        #expect(log.latestSeq == 0)
        #expect(log.health == "failing")
        #expect(await log.events(after: 0).isEmpty)
        try db.exec("DROP TRIGGER reject_reservation")
        let recorded = hub.publish(lamp(false))
        var iterator = subscription.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.event == recorded)
        #expect(received?.event.seq == 1)
        #expect(await log.stats().dropped == 1)
    }
}

private final class StateRegressionFixture: Sendable {
    let root: URL
    let path: URL
    let clock: TestClock
    let log: EventLog
    let hub: EventHub
    let states: StateStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "homerelay-state-regression-\(UUID().uuidString)")
        self.root = root
        path = root.appending(path: "states/states.json")
        let clock = TestClock()
        self.clock = clock
        let log = try EventLog(path: root.appending(path: "log/hot.sqlite"), clock: { clock.date })
        self.log = log
        let hub = EventHub(log: log)
        self.hub = hub
        states = try StateStore(path: path, hub: hub, clock: { clock.date })
    }

    func disk() throws -> [String: JSONValue] {
        guard case .object(let result) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path)) else {
            throw APIError.badRequest("Expected State file")
        }
        return result
    }

    deinit {
        log.close()
        try? FileManager.default.removeItem(at: root)
    }
}

struct StateRegressionTests {
    @Test func failedStateMutationsLeaveMemoryDiskEventsAndObserversUnchanged() async throws {
        let f = try StateRegressionFixture()
        let original = try await f.states.create(name: "Example", kind: "switch", resetAfter: nil, by: nil)
        let saved = try Data(contentsOf: f.path)
        let notifications = Mutex(0)
        await f.states.observe { _ in notifications.withLock { $0 += 1 } }
        let seq = f.log.latestSeq
        let parent = f.path.deletingLastPathComponent()
        let moved = f.root.appending(path: "saved-states")
        try FileManager.default.moveItem(at: parent, to: moved)
        try Data().write(to: parent) // a file blocks creation of the storage directory
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.moveItem(at: moved, to: parent)
        }
        await #expect(throws: APIError.self) { try await f.states.create(name: "Another", kind: "switch", resetAfter: nil, by: nil) }
        await #expect(throws: APIError.self) { try await f.states.set(original.id, on: true, by: nil) }
        await #expect(throws: APIError.self) { try await f.states.update(original.id, name: "Changed", resetAfter: nil) }
        await #expect(throws: APIError.self) { try await f.states.delete(original.id) }
        #expect(await f.states.list() == [original])
        #expect(try Data(contentsOf: moved.appending(path: "states.json")) == saved)
        #expect(f.log.latestSeq == seq)
        #expect(notifications.withLock { $0 } == 1)
    }

    @Test func retiredSlugsSurviveReloadAndLegacyFilesStillLoad() async throws {
        let f = try StateRegressionFixture()
        let first = try await f.states.create(name: "Example", kind: "switch", resetAfter: nil, by: nil)
        // Old files don't contain the new fields.
        var legacy = try f.disk()
        legacy["retiredIds"] = nil
        legacy["resetDeadlines"] = nil
        try JSONEncoder().encode(legacy).write(to: f.path)
        let old = try StateStore(path: f.path, hub: f.hub)
        try await old.delete(first.id)
        let reloaded = try StateStore(path: f.path, hub: f.hub)
        let replacement = try await reloaded.create(name: "Example", kind: "switch", resetAfter: nil, by: nil)
        #expect(replacement.id == "example-2")
        #expect(replacement.aid > first.aid)
        #expect(replacement.characteristicId != first.characteristicId)
        #expect(try f.disk()["retiredIds"] == .array([.string(first.id)]))
        await #expect(throws: APIError.self) { try await reloaded.get(first.id) }
        await #expect(throws: APIError.self) { try await reloaded.get(first.accessoryId) }
    }

    @Test func resetDeadlineSurvivesRestartAndExpiresOverdueImmediately() async throws {
        let f = try StateRegressionFixture()
        let state = try await f.states.create(name: "Example", kind: "switch", resetAfter: 3_600, by: nil)
        _ = try await f.states.set(state.id, on: true, by: nil)
        let deadlines = try f.disk()["resetDeadlines"]
        f.clock.advance(3_000)
        let resumed = try StateStore(path: f.path, hub: f.hub, clock: { f.clock.date })
        await resumed.start()
        #expect(try await resumed.get(state.id).on)
        #expect(try f.disk()["resetDeadlines"] == deadlines)
        f.clock.advance(601)
        let overdue = try StateStore(path: f.path, hub: f.hub, clock: { f.clock.date })
        await overdue.start()
        #expect(try await overdue.get(state.id).on == false)
        #expect(try await overdue.get(state.id).updatedBy == "reset")
        #expect(try f.disk()["resetDeadlines"] == .object([:]))
    }

    @Test func legacyResetDeadlineUsesUpdatedAtInsteadOfRestartTime() async throws {
        let f = try StateRegressionFixture()
        let state = try await f.states.create(name: "Example", kind: "switch", resetAfter: 60, by: nil)
        _ = try await f.states.set(state.id, on: true, by: nil)
        var legacy = try f.disk()
        legacy["resetDeadlines"] = nil
        legacy["retiredIds"] = nil
        try JSONEncoder().encode(legacy).write(to: f.path)
        f.clock.advance(61)
        let migrated = try StateStore(path: f.path, hub: f.hub, clock: { f.clock.date })
        await migrated.start()
        #expect(try await migrated.get(state.id).on == false)
    }

    @Test func resetUpdatesValidateAndReconcileTimers() async throws {
        let (states, path) = try StateTests().store()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let state = try await states.create(name: "Example", kind: "switch", resetAfter: 1, by: nil)
        _ = try await states.set(state.id, on: true, by: nil)
        for bad in [0, -1, 86_401] {
            await #expect(throws: APIError.self) { try await states.update(state.id, name: nil, resetAfter: .some(bad)) }
        }
        _ = try await states.update(state.id, name: nil, resetAfter: .some(nil))
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(try await states.get(state.id).on)
        // Adding a reset to a State that is already on must schedule it.
        _ = try await states.update(state.id, name: nil, resetAfter: .some(1))
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(try await states.get(state.id).on == false)
    }

    @Test func stateCreationAndStartupSamplesProvideHistoryCoverage() async throws {
        let f = try StateRegressionFixture()
        let state = try await f.states.create(name: "Example", kind: "switch", resetAfter: nil, by: nil)
        let created = await f.log.events(after: 0)
        #expect(created.contains { $0.characteristicId == state.characteristicId && $0.origin == "sample" && $0.value == .bool(false) })
        f.log.close()
        f.clock.advance(10)
        let log = try EventLog(path: f.log.path, clock: { f.clock.date })
        defer { log.close() }
        let states = try StateStore(path: f.path, hub: EventHub(log: log), clock: { f.clock.date })
        await states.start()
        f.clock.advance(60)
        let history = History(dir: nil, backups: nil, log: log, clock: { f.clock.date })
        let summary = try await history.summary(state.characteristicId, window: .seconds(30))
        #expect(summary.current == 0)
        #expect(summary.summary.coverage == 30)
    }
}

struct RouterRegressionTests {
    @Test func documentedAliasesRemainAvailable() async throws {
        let (states, path) = try StateTests().store()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let server = try await TestServer(states: states)
        #expect(try await server.request("POST", "/api/v1/states", body: #"{"name":"Alias example"}"#).0 == 201)
        for method in ["PUT", "POST", "PATCH"] {
            #expect(try await server.request(method, "/api/v1/states/alias-example", body: #"{"on":true}"#).0 == 200)
        }
        let (status, body) = try await server.request("GET", "/api/v1/states/alias-example", token: TestServer.read)
        #expect(status == 200)
        #expect(try server.object(body)["on"] == .bool(true))
        for method in ["POST", "PATCH"] {
            #expect(try await server.request(method, "/api/v1/accessories/LAMP-1", body: #"{"on":true}"#).0 == 200)
        }
    }

    @Test func roomQualifiedTwinsReturn409AndCandidates() throws {
        let twins = [Named(id: "one", name: "Lamp", room: "Office"), Named(id: "two", name: "Lamp", room: "Office")]
        do {
            _ = try RefResolver.resolve("Office/Lamp", in: twins, kind: "accessory")
            Issue.record("Expected ambiguity")
        } catch {
            #expect(error.status == 409)
            #expect(error.code == "ambiguous")
            #expect(error.candidates == ["Office/Lamp (one)", "Office/Lamp (two)"])
        }
    }

    @Test func healthRoutesRejectOtherMethodsAndAdvertiseAllow() async throws {
        let router = APIRouter(backend: FakeHome(), tokens: TokenStore(path: tempLogURL()), events: EventHub(), version: "test")
        for suffix in [[], ["ready"], ["history"], ["bridge"]] {
            let segments = ["api", "v1", "health"] + suffix
            #expect(await router.handle(HTTPRequest(method: "GET", segments: segments)).status == 200)
            // The HTTP server currently has no HEAD body-suppression support.
            for method in ["POST", "PUT", "PATCH", "DELETE", "HEAD"] {
                let response = await router.handle(HTTPRequest(method: method, segments: segments))
                #expect(response.status == 405)
                #expect(response.headers.contains { $0.0 == "Allow" && $0.1 == "GET" })
            }
            // Browsers send a CORS preflight first; it must not be refused.
            let preflight = await router.handle(HTTPRequest(method: "OPTIONS", segments: segments))
            #expect(preflight.status < 300)
            #expect(preflight.headers.contains { $0.0 == "Access-Control-Allow-Origin" })
        }
    }
}
