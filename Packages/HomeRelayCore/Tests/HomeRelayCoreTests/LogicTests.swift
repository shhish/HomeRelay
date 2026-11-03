import Foundation
import Testing
@testable import HomeRelayCore

@Suite struct ValueCoercionTests {
    let percent = ValueSpec(format: "int", min: 0, max: 100, step: 1)

    @Test func clampsAndRoundsIntegers() throws {
        #expect(try ValueCoercion.coerce(.int(150), to: percent) == .int(100))
        #expect(try ValueCoercion.coerce(.double(42.6), to: percent) == .int(43))
        #expect(try ValueCoercion.coerce(.string("-5"), to: percent) == .int(0))
    }

    @Test func snapsFloatsToStep() throws {
        let temp = ValueSpec(format: "float", min: 10, max: 38, step: 0.5)
        #expect(try ValueCoercion.coerce(.double(21.3), to: temp) == .double(21.5))
        #expect(try ValueCoercion.coerce(.int(99), to: temp) == .double(38))
    }

    @Test func acceptsLooseBooleans() throws {
        let spec = ValueSpec(format: "bool")
        #expect(try ValueCoercion.coerce(.string("on"), to: spec) == .bool(true))
        #expect(try ValueCoercion.coerce(.int(0), to: spec) == .bool(false))
        #expect(throws: APIError.self) { try ValueCoercion.coerce(.string("maybe"), to: spec) }
    }

    @Test func enforcesValidValues() {
        let spec = ValueSpec(format: "uint8", min: 0, max: 3, step: 1, validValues: [0, 1, 3])
        #expect(throws: APIError.self) { try ValueCoercion.coerce(.int(2), to: spec) }
    }

    @Test func rejectsUnsupportedFormats() {
        #expect(throws: APIError.self) { try ValueCoercion.coerce(.string("AQID"), to: ValueSpec(format: "tlv8")) }
    }
}

@Suite struct WritePlannerTests {
    @Test func powerGoesBeforeOtherValues() throws {
        let lamp = FakeHome.makeLamp(on: false, brightness: 10)
        let writes = try WritePlanner.plan(["brightness": .int(80), "on": .bool(true)], for: lamp)
        #expect(writes.map(\.type) == ["on", "brightness"])
        #expect(writes[1].value == .int(80))
    }

    @Test func turningOffGoesLast() throws {
        let lamp = FakeHome.makeLamp(on: true, brightness: 10)
        let writes = try WritePlanner.plan(["on": .bool(false), "brightness": .int(50)], for: lamp)
        #expect(writes.map(\.type) == ["brightness", "on"])
    }

    @Test func onFallsBackToActive() async throws {
        let fan = await FakeHome().fan
        let writes = try WritePlanner.plan(["on": .bool(true)], for: fan)
        #expect(writes == [PlannedWrite(characteristicId: "C-ACT", type: "active", value: .int(1))])
    }

    @Test func lockedMapsToLockTarget() async throws {
        let lock = await FakeHome().lock
        let writes = try WritePlanner.plan(["locked": .bool(false)], for: lock)
        #expect(writes == [PlannedWrite(characteristicId: "C-LT", type: "lockTarget", value: .int(0))])
    }

    @Test func unknownKeyListsWhatIsWritable() {
        let lamp = FakeHome.makeLamp(on: true, brightness: 10)
        do {
            _ = try WritePlanner.plan(["hue": .int(10)], for: lamp)
            Issue.record("expected an error")
        } catch {
            #expect(error.status == 422)
            #expect(error.message.contains("brightness, on"))
        }
    }

    @Test func informationServiceIsNotWritableByName() {
        let lamp = FakeHome.makeLamp(on: true, brightness: 10)
        #expect(throws: APIError.self) { try WritePlanner.plan(["name": .string("x")], for: lamp) }
    }

    @Test func toggleFlipsCurrentState() throws {
        let on = FakeHome.makeLamp(on: true, brightness: 10)
        #expect(try WritePlanner.toggle(on).value == .bool(false))
        let off = FakeHome.makeLamp(on: false, brightness: 10)
        #expect(try WritePlanner.toggle(off).value == .bool(true))
    }
}

@Suite struct ResolverAndNamingTests {
    let items = [
        Named(id: "A", name: "Lamp", room: "Office"),
        Named(id: "B", name: "Lamp", room: "Bedroom"),
        Named(id: "C", name: "Fan", room: "Bedroom"),
    ]

    @Test func resolvesByIdThenName() throws {
        #expect(try RefResolver.resolve("b", in: items, kind: "accessory").id == "B")
        #expect(try RefResolver.resolve("fan", in: items, kind: "accessory").id == "C")
    }

    @Test func ambiguousNamesNeedARoom() throws {
        do {
            _ = try RefResolver.resolve("Lamp", in: items, kind: "accessory")
            Issue.record("expected ambiguity")
        } catch {
            #expect(error.status == 409)
            #expect(error.candidates == ["Office/Lamp (A)", "Bedroom/Lamp (B)"])
        }
        #expect(try RefResolver.resolve("bedroom/lamp", in: items, kind: "accessory").id == "B")
    }

    @Test func camelCasesLabels() {
        #expect(Naming.camelCase("Current Temperature") == "currentTemperature")
        #expect(Naming.camelCase("PM2.5 Density") == "pm25Density")
        #expect(Naming.camelCase("") == "unknown")
    }

    @Test func infersCategoryForBridgedAccessories() {
        #expect(CategoryInference.infer(reported: "other", serviceTypes: ["custom.1a2b3c4d", "lightbulb"]) == "lightbulb")
        #expect(CategoryInference.infer(reported: "other", serviceTypes: ["battery", "motionSensor"]) == "sensor")
        #expect(CategoryInference.infer(reported: "other", serviceTypes: ["custom.1a2b3c4d"]) == "other")
        #expect(CategoryInference.infer(reported: "bridge", serviceTypes: ["switch"]) == "bridge")
    }

    @Test func stateSkipsVendorAndInfoValues() {
        let service = ServiceDTO(id: "S", type: "lightbulb", name: "x", primary: true, characteristics: [
            CharacteristicDTO(id: "1", type: "on", label: "Power State", value: .bool(true), format: "bool", unit: nil, min: nil, max: nil, step: nil, validValues: nil, readable: true, writable: true, notifies: true),
            CharacteristicDTO(id: "2", type: "custom.1a2b3c4d", label: "Custom", value: .string("x"), format: "string", unit: nil, min: nil, max: nil, step: nil, validValues: nil, readable: true, writable: false, notifies: false),
            CharacteristicDTO(id: "3", type: "model", label: "Model", value: .string("M1"), format: "string", unit: nil, min: nil, max: nil, step: nil, validValues: nil, readable: true, writable: false, notifies: false),
        ])
        let a = AccessoryDTO(id: "A", name: "x", home: "h", room: nil, category: "lightbulb", reachable: true, bridged: false, manufacturer: nil, model: nil, services: [service])
        #expect(a.state == ["on": .bool(true)])
        #expect(a.compact.services.isEmpty && a.compact.state == a.state)
    }

    @Test func stateSummaryPrefersPrimaryAndSkipsInfo() {
        let lamp = FakeHome.makeLamp(on: true, brightness: 55)
        #expect(lamp.state == ["on": .bool(true), "brightness": .int(55)])
    }
}

@Suite struct TokenStoreTests {
    @Test func verifiesHashedTokensAndReloadsOnChange() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "homerelay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "tokens.json")
        let store = TokenStore(path: file)
        #expect(store.verify("secret-1") == nil)

        try write([TokenRecord(name: "orb", scope: .control, sha256: TokenStore.hash("secret-1"))], to: file)
        #expect(store.verify("secret-1")?.name == "orb")
        #expect(store.verify("secret-2") == nil)

        // A different modification time triggers a reload.
        try write([TokenRecord(name: "esp32", scope: .read, sha256: TokenStore.hash("secret-2"))], to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(store.verify("secret-1") == nil)
        #expect(store.verify("secret-2")?.scope == .read)
    }

    private func write(_ records: [TokenRecord], to file: URL) throws {
        struct Shape: Encodable { var tokens: [TokenRecord] }
        try JSONEncoder().encode(Shape(tokens: records)).write(to: file)
    }
}
