import Foundation
@testable import HomeRelayCore

/// In-memory home with a dimmable lamp, a fan that uses `active`, a lock and two scenes.
actor FakeHome: HomeBackend {
    var lamp = FakeHome.makeLamp(on: false, brightness: 30)
    var fanActive = 0
    var lockTarget = 1
    var ranScenes: [String] = []
    /// Request context seen by the last write, as the real backend would label its events.
    var lastWriteContext: (caller: String?, cause: String?)?
    var ready = true

    static func makeLamp(on: Bool, brightness: Int) -> AccessoryDTO {
        AccessoryDTO(
            id: "LAMP-1", name: "Desk Lamp", home: "Home", room: "Office", category: "lightbulb",
            reachable: true, bridged: true, manufacturer: "Govee", model: "H6001",
            services: [
                ServiceDTO(id: "S-INFO", type: "accessoryInformation", name: "Desk Lamp", primary: false, characteristics: [
                    CharacteristicDTO(id: "C-NAME", type: "name", label: "Name", value: .string("Desk Lamp"), format: "string", unit: nil, min: nil, max: nil, step: nil, validValues: nil, readable: true, writable: false, notifies: false),
                ]),
                ServiceDTO(id: "S-LIGHT", type: "lightbulb", name: "Desk Lamp", primary: true, characteristics: [
                    CharacteristicDTO(id: "C-ON", type: "on", label: "Power State", value: .bool(on), format: "bool", unit: nil, min: nil, max: nil, step: nil, validValues: nil, readable: true, writable: true, notifies: true),
                    CharacteristicDTO(id: "C-BRI", type: "brightness", label: "Brightness", value: .int(brightness), format: "int", unit: "percentage", min: 0, max: 100, step: 1, validValues: nil, readable: true, writable: true, notifies: true),
                ]),
            ]
        )
    }

    var fan: AccessoryDTO {
        AccessoryDTO(
            id: "FAN-1", name: "Tower Fan", home: "Home", room: "Bedroom", category: "fan",
            reachable: true, bridged: true, manufacturer: nil, model: nil,
            services: [
                ServiceDTO(id: "S-FAN", type: "fan", name: "Tower Fan", primary: true, characteristics: [
                    CharacteristicDTO(id: "C-ACT", type: "active", label: "Active", value: .int(fanActive), format: "uint8", unit: nil, min: 0, max: 1, step: 1, validValues: [0, 1], readable: true, writable: true, notifies: true),
                ]),
            ]
        )
    }

    var lock: AccessoryDTO {
        AccessoryDTO(
            id: "LOCK-1", name: "Front Door", home: "Home", room: "Hall", category: "doorLock",
            reachable: true, bridged: false, manufacturer: nil, model: nil,
            services: [
                ServiceDTO(id: "S-LOCK", type: "lockMechanism", name: "Front Door", primary: true, characteristics: [
                    CharacteristicDTO(id: "C-LT", type: "lockTarget", label: "Lock Mechanism Target State", value: .int(lockTarget), format: "uint8", unit: nil, min: 0, max: 1, step: 1, validValues: [0, 1], readable: true, writable: true, notifies: true),
                ]),
            ]
        )
    }

    var all: [AccessoryDTO] { [lamp, fan, lock] }

    func setReady(_ value: Bool) { ready = value }

    func status() async -> BackendStatus { BackendStatus(state: ready ? "ready" : "starting") }

    func homes() async throws -> [HomeSummary] {
        [HomeSummary(id: "HOME-1", name: "Home", rooms: 3, accessories: 3, scenes: 2)]
    }

    func snapshot(home: String?, refresh: Bool) async throws -> [HomeDTO] {
        [HomeDTO(id: "HOME-1", name: "Home", rooms: try await rooms(home: home), accessories: all, scenes: try await scenes(home: home))]
    }

    func rooms(home: String?) async throws -> [RoomDTO] {
        [
            RoomDTO(id: "R-OFFICE", name: "Office", home: "Home", accessoryIds: ["LAMP-1"]),
            RoomDTO(id: "R-BED", name: "Bedroom", home: "Home", accessoryIds: ["FAN-1"]),
            RoomDTO(id: "R-HALL", name: "Hall", home: "Home", accessoryIds: ["LOCK-1"]),
        ]
    }

    func accessories(home: String?, room: String?, category: String?, refresh: Bool) async throws -> [AccessoryDTO] {
        all.filter { room == nil || $0.room?.lowercased() == room?.lowercased() }
            .filter { category == nil || $0.category == category }
    }

    func accessory(_ ref: String, home: String?, refresh: Bool) async throws -> AccessoryDTO {
        let named = try RefResolver.resolve(ref, in: all.map { Named(id: $0.id, name: $0.name, room: $0.room) }, kind: "accessory")
        return all.first { $0.id == named.id }!
    }

    func setAccessory(_ ref: String, home: String?, values: [String: JSONValue]) async throws -> AccessoryDTO {
        let target = try await accessory(ref, home: home, refresh: false)
        lastWriteContext = (RequestContext.caller, RequestContext.cause)
        for write in try WritePlanner.plan(values, for: target) { apply(write) }
        return try await accessory(target.id, home: home, refresh: false)
    }

    func toggleAccessory(_ ref: String, home: String?) async throws -> AccessoryDTO {
        let target = try await accessory(ref, home: home, refresh: false)
        apply(try WritePlanner.toggle(target))
        return try await accessory(target.id, home: home, refresh: false)
    }

    func writeCharacteristic(id: String, value: JSONValue) async throws -> CharacteristicDTO {
        guard let c = all.flatMap(\.controllable).first(where: { $0.id == id }) else { throw APIError.notFound("No characteristic \(id)") }
        apply(PlannedWrite(characteristicId: id, type: c.type, value: try ValueCoercion.coerce(value, to: c.spec)))
        return all.flatMap(\.controllable).first { $0.id == id }!
    }

    func scenes(home: String?) async throws -> [SceneDTO] {
        [SceneDTO(id: "SC-1", name: "Good Night", home: "Home", kind: "sleep"), SceneDTO(id: "SC-2", name: "Movie", home: "Home", kind: "user")]
    }

    func runScene(_ ref: String, home: String?) async throws -> SceneDTO {
        let list = try await scenes(home: home)
        let named = try RefResolver.resolve(ref, in: list.map { Named(id: $0.id, name: $0.name) }, kind: "scene")
        ranScenes.append(named.id)
        return list.first { $0.id == named.id }!
    }

    private func apply(_ write: PlannedWrite) {
        switch (write.characteristicId, write.value) {
        case ("C-ON", .bool(let on)):
            lamp = Self.makeLamp(on: on, brightness: lamp.state["brightness"].flatMap(\.doubleValue).map { Int($0) } ?? 0)
        case ("C-BRI", .int(let b)):
            lamp = Self.makeLamp(on: lamp.state["on"]?.boolValue ?? false, brightness: b)
        case ("C-ACT", .int(let v)):
            fanActive = v
        case ("C-LT", .int(let v)):
            lockTarget = v
        default:
            break
        }
    }
}
