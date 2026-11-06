// HAPBridgeTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
@testable import HAPTransport

@Suite("HAPBridge Tests")
struct HAPBridgeTests {

    private func makeBridge() -> HAPBridge {
        HAPBridge(info: AccessoryInfo(
            name: "Test Bridge",
            manufacturer: "Acumen",
            model: "Bridge1",
            serialNumber: "001",
            firmwareRevision: "1.0.0"
        ))
    }

    @Test("bridge is AID=1")
    func bridgeIsAID1() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)
        #expect(db[0].aid == 1)
    }

    @Test("bridge has accessory information service")
    func bridgeHasInfo() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        #expect(db[0].services[0].type == .accessoryInformation)
        #expect(db[0].name == "Test Bridge")
    }

    @Test("add accessory assigns next AID")
    func addAccessoryAID() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(
                name: "Panel", manufacturer: "Acumen", model: "P1",
                serialNumber: "002", firmwareRevision: "1.0.0"
            ),
            services: [securityService]
        )
        #expect(aid == 2)

        let db = await bridge.accessoryDatabase()
        #expect(db.count == 2)
    }

    @Test("multiple accessories get sequential AIDs")
    func sequentialAIDs() async throws {
        let bridge = makeBridge()
        let aid1 = try await bridge.addAccessory(
            info: AccessoryInfo(name: "A", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: []
        )
        let aid2 = try await bridge.addAccessory(
            info: AccessoryInfo(name: "B", manufacturer: "M", model: "M", serialNumber: "2", firmwareRevision: "1.0"),
            services: []
        )
        #expect(aid1 == 2)
        #expect(aid2 == 3)
    }

    @Test("remove accessory")
    func removeAccessory() async throws {
        let bridge = makeBridge()
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "A", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: []
        )
        try await bridge.removeAccessory(aid: aid)
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)  // Only bridge remains
    }

    @Test("cannot remove bridge")
    func cannotRemoveBridge() async throws {
        let bridge = makeBridge()
        try await bridge.removeAccessory(aid: 1)
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)  // Bridge still there
    }

    @Test("read characteristic")
    func readCharacteristic() async {
        let bridge = makeBridge()
        // Service iid=1, name characteristic iid=2 (service occupies the startIID slot)
        let value = await bridge.readCharacteristic(aid: 1, iid: 2)
        #expect(value == .string("Test Bridge"))
    }

    @Test("write characteristic")
    func writeCharacteristic() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: [securityService]
        )

        // Find the targetSecuritySystemState IID (it's in the second service)
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let secSvc = accessory.services.first(where: { $0.type == .securitySystem })!
        let targetChar = secSvc.characteristics.first(where: { $0.type == .targetSecuritySystemState })!

        try await bridge.writeCharacteristic(aid: aid, iid: targetChar.iid, value: .uint8(1))
        let written = await bridge.readCharacteristic(aid: aid, iid: targetChar.iid)
        #expect(written == .uint8(1))
    }
}
