import Foundation
import Testing
@testable import HomeRelayCore

@Suite(.serialized) struct StateTests {
    func store(_ hub: EventHub = EventHub()) throws -> (StateStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "homerelay-states-\(UUID().uuidString)/states.json")
        return (try StateStore(path: url, hub: hub), url)
    }

    @Test func createSetAndPersist() async throws {
        let hub = EventHub()
        let stream = hub.subscribe()
        let (states, url) = try store(hub)
        let guest = try await states.create(name: "Guest mode", kind: "switch", resetAfter: nil, by: "orb")
        #expect(guest.id == "guest-mode")
        #expect(guest.aid == 2)
        let twin = try await states.create(name: "Guest  Mode!", kind: "contact", resetAfter: nil, by: "orb")
        #expect(twin.id == "guest-mode-2")
        await #expect(throws: APIError.self) { try await states.create(name: "guest mode", kind: "switch", resetAfter: nil, by: nil) }
        await #expect(throws: APIError.self) { try await states.create(name: "x", kind: "lamp", resetAfter: nil, by: nil) }

        let on = try await states.set("Guest mode", on: true, by: "dot", cause: "routine:run_1")
        #expect(on.on)
        var iterator = stream.makeAsyncIterator()
        var events: [HomeEvent] = []
        while events.count < 3, let item = await iterator.next() { events.append(item.event) }
        let change = try #require(events.last)
        #expect(change.type == "characteristic")
        #expect(change.accessoryId == "state:guest-mode")
        #expect(change.characteristicId == "state:guest-mode:on")
        #expect(change.value == .bool(true))
        #expect(change.by == "dot")
        #expect(change.cause == "routine:run_1")

        // A new store reads the same file; ids and bridge accessory ids stay.
        let reloaded = try StateStore(path: url, hub: EventHub())
        #expect(await reloaded.list().map(\.id) == ["guest-mode", "guest-mode-2"])
        #expect(try await reloaded.get("state:guest-mode").on)
        try await reloaded.delete("guest-mode")
        let next = try await reloaded.create(name: "Movie time", kind: "switch", resetAfter: nil, by: nil)
        #expect(next.aid == 4) // never reuses a deleted accessory's id
    }

    @Test func resetAfterTurnsItselfOff() async throws {
        let (states, _) = try store()
        _ = try await states.create(name: "Doorbell rang", kind: "motion", resetAfter: 1, by: nil)
        _ = try await states.set("Doorbell rang", on: true, by: "routine")
        #expect(try await states.get("doorbell-rang").on)
        try await Task.sleep(for: .milliseconds(1_300))
        let after = try await states.get("doorbell-rang")
        #expect(!after.on)
        #expect(after.updatedBy == "reset")
    }

    @Test func limitMatchesOneBridge() async throws {
        let (states, _) = try store()
        for i in 0..<VirtualState.limit { _ = try await states.create(name: "S\(i)", kind: "switch", resetAfter: nil, by: nil) }
        await #expect(throws: APIError.self) { try await states.create(name: "One too many", kind: "switch", resetAfter: nil, by: nil) }
    }

    @Test func routes() async throws {
        let hub = EventHub()
        let (states, _) = try store(hub)
        let server = try await TestServer(events: hub, states: states)
        let (created, body) = try await server.request("POST", "/api/v1/states", body: #"{"name": "Guest mode", "kind": "switch", "resetAfter": 3600}"#)
        #expect(created == 201)
        #expect(try server.object(body)["id"] == .string("guest-mode"))
        #expect(try await server.request("POST", "/api/v1/states", token: TestServer.read, body: #"{"name": "Nope"}"#).0 == 403)
        let (set, setBody) = try await server.request("PUT", "/api/v1/states/Guest%20mode", body: #"{"on": true}"#)
        #expect(set == 200)
        #expect(try server.object(setBody)["on"] == .bool(true))
        #expect(try await server.request("PATCH", "/api/v1/states/guest-mode", body: #"{"resetAfter": null, "name": "Guests"}"#).0 == 200)
        let (_, list) = try await server.request("GET", "/api/v1/states", token: TestServer.read)
        #expect(String(decoding: list, as: UTF8.self).contains("\"name\":\"Guests\""))
        #expect(try await server.request("PUT", "/api/v1/states/guests", body: #"{"on": "maybe"}"#).0 == 422)
        #expect(try await server.request("DELETE", "/api/v1/states/guests").0 == 200)
        #expect(try await server.request("GET", "/api/v1/states/guests", token: TestServer.read).0 == 404)
    }
}
