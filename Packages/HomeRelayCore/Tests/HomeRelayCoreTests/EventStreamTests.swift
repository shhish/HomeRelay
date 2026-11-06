import Foundation
import Testing
@testable import HomeRelayCore

/// Reads server-sent-event frames from a live `/events` connection.
struct SSEReader {
    struct Frame: Equatable {
        var id: String?
        var event: String?
        var data: String
    }

    private var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator

    init(_ server: TestServer, query: String = "", lastEventId: String? = nil) async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/v1/events\(query)")!)
        req.setValue("Bearer \(TestServer.read)", forHTTPHeaderField: "Authorization")
        if let lastEventId { req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        lines = bytes.lines.makeAsyncIterator()
    }

    /// The next frame with data (comments and keepalives are skipped).
    mutating func next() async throws -> Frame? {
        var frame = Frame(data: "")
        var sawData = false
        // URLSession's line reader drops empty lines, so a frame ends at its data line.
        while let line = try await lines.next() {
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("id: ") { frame.id = String(line.dropFirst(4)) }
            if line.hasPrefix("event: ") { frame.event = String(line.dropFirst(7)) }
            if line.hasPrefix("data: ") {
                frame.data = String(line.dropFirst(6))
                sawData = true
                break
            }
        }
        return sawData ? frame : nil
    }

    func value(_ frame: Frame, _ key: String) throws -> JSONValue? {
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(frame.data.utf8)) else { return nil }
        return o[key]
    }
}

@Suite(.serialized) struct EventStreamTests {
    func loggedServer(_ settings: EventLog.Settings = EventLog.Settings()) async throws -> TestServer {
        try await TestServer(events: EventHub(log: try EventLog(path: tempLogURL(), settings: settings)))
    }

    @Test func liveEventsCarryIds() async throws {
        let server = try await loggedServer()
        var reader = try await SSEReader(server)
        while server.events.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        server.events.publish(lamp(true))
        server.events.record(lamp(true, origin: "sample"))
        server.events.publish(lamp(false))
        let a = try #require(try await reader.next())
        let b = try #require(try await reader.next())
        #expect(a.id == "1")
        #expect(a.event == "characteristic")
        #expect(try reader.value(a, "origin") == .string("notification"))
        #expect(b.id == "3")
    }

    @Test func resumesFromSinceAndLastEventIdWithoutDuplicates() async throws {
        let server = try await loggedServer()
        for i in 0..<5 { server.events.publish(lamp(i % 2 == 0)) }
        server.events.log!.flush()
        server.events.publish(lamp(true)) // seq 6, still queued

        var reader = try await SSEReader(server, query: "?since=3")
        #expect(try await reader.next()?.id == "4")
        #expect(try await reader.next()?.id == "5")
        #expect(try await reader.next()?.id == "6")
        server.events.publish(lamp(false))
        #expect(try await reader.next()?.id == "7")

        var header = try await SSEReader(server, lastEventId: "6")
        #expect(try await header.next()?.id == "7")
    }

    @Test func announcesGapsForExpiredAndResetPositions() async throws {
        let server = try await loggedServer()
        for _ in 0..<4 { server.events.publish(lamp(true)) }
        server.events.log!.flush()
        let db = try SQLiteDB(path: server.events.log!.path.path)
        try db.run("DELETE FROM events WHERE seq <= 2")

        var expired = try await SSEReader(server, query: "?since=0")
        let gap = try #require(try await expired.next())
        #expect(gap.event == "gap")
        #expect(try expired.value(gap, "reason") == .string("expired"))
        #expect(try expired.value(gap, "missingFrom") == .int(1))
        #expect(try expired.value(gap, "missingTo") == .int(2))
        #expect(gap.id == "2")
        #expect(try await expired.next()?.id == "3")

        var reset = try await SSEReader(server, query: "?since=99")
        let r = try #require(try await reset.next())
        #expect(try reset.value(r, "reason") == .string("reset"))
        #expect(try reset.value(r, "ts") != nil)
        #expect(r.id == "4")

        // A position from another install is a reset even when it's in range.
        var other = try await SSEReader(server, query: "?since=3&store=SOMEWHERE-ELSE")
        let o = try #require(try await other.next())
        #expect(try other.value(o, "reason") == .string("reset"))
        let store = server.events.log!.storeId
        var same = try await SSEReader(server, query: "?since=3&store=\(store)")
        #expect(try await same.next()?.id == "4")
    }

    @Test func slowClientsCatchUpFromTheLog() async throws {
        let server = try await loggedServer()
        var reader = try await SSEReader(server)
        while server.events.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        server.events.publish(lamp(true))
        #expect(try await reader.next()?.id == "1")
        // Far more than the per-subscriber buffers hold, while the client isn't reading.
        for i in 0..<3_000 { server.events.publish(lamp(i % 2 == 0)) }
        var ids: [Int] = []
        while ids.last != 3_001, let frame = try await reader.next() {
            #expect(frame.event == "characteristic")
            if let id = frame.id.flatMap(Int.init) { ids.append(id) }
        }
        #expect(ids == Array(2...3_001))
    }

    @Test func filterAppliesToReplay() async throws {
        let server = try await loggedServer()
        server.events.publish(HomeEvent(type: "characteristic", accessoryId: "FAN-1", characteristic: "active", value: .int(1)))
        server.events.publish(lamp(true))
        var reader = try await SSEReader(server, query: "?since=0&accessory=LAMP-1")
        let frame = try #require(try await reader.next())
        #expect(frame.id == "2")
    }

    @Test func disconnectedClientsUnsubscribe() async throws {
        let server = try await loggedServer()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/v1/events")!)
        req.setValue("Bearer \(TestServer.read)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let reading = Task {
            let (bytes, _) = try await session.bytes(for: req)
            for try await _ in bytes.lines {}
        }
        while server.events.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        reading.cancel()
        session.invalidateAndCancel()
        // The next keepalive (every 200 ms here) fails to write and ends the session.
        let deadline = ContinuousClock.now + .seconds(5)
        while server.events.subscriberCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(server.events.subscriberCount == 0)
    }

    @Test func rejectsBadSince() async throws {
        let server = try await loggedServer()
        #expect(try await server.request("GET", "/api/v1/events?since=abc", token: TestServer.read).0 == 400)
    }

    @Test func statsAndHealthReportTheLog() async throws {
        let server = try await loggedServer()
        server.events.publish(lamp(true))
        let (status, data) = try await server.request("GET", "/api/v1/events/stats", token: TestServer.read)
        #expect(status == 200)
        let stats = try server.object(data)
        #expect(stats["latestSeq"] == .int(1))
        #expect(stats["byOrigin"] == .object(["notification": .int(1)]))
        let (_, health) = try await server.request("GET", "/api/v1/health", token: nil)
        #expect(try server.object(health)["eventLog"] == .string("ok"))
        let plain = try await TestServer()
        #expect(try await plain.request("GET", "/api/v1/events/stats", token: TestServer.read).0 == 404)
    }

    @Test func writesCarryCallerAndCause() async throws {
        let server = try await TestServer()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/v1/accessories/LAMP-1")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"on": true}"#.utf8)
        req.setValue("Bearer \(TestServer.control)", forHTTPHeaderField: "Authorization")
        req.setValue("routine:hall-1", forHTTPHeaderField: "X-HomeRelay-Cause")
        let (_, response) = try await URLSession.shared.data(for: req)
        #expect((response as! HTTPURLResponse).statusCode == 200)
        let context = await server.home.lastWriteContext
        #expect(context?.caller == "ctl")
        #expect(context?.cause == "routine:hall-1")
    }
}
