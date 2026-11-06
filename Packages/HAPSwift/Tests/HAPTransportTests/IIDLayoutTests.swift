// IIDLayoutTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
import HAPCrypto
@testable import HAPTransport

@Suite("IID Layout Tests")
struct IIDLayoutTests {

    private func makeBridge() -> HAPBridge {
        HAPBridge(info: AccessoryInfo(
            name: "Test Bridge",
            manufacturer: "Acumen",
            model: "Bridge1",
            serialNumber: "001",
            firmwareRevision: "1.0.0"
        ))
    }

    // MARK: - Bridge Accessory IID Layout

    @Test("bridge accessory information service is at iid=1")
    func bridgeInfoServiceIID() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        let bridgeAccessory = db[0]
        let infoService = bridgeAccessory.services[0]
        #expect(infoService.iid == 1)
        #expect(infoService.type == .accessoryInformation)
    }

    @Test("bridge name characteristic is at iid=2")
    func bridgeNameCharIID() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        let infoService = db[0].services[0]
        let nameChar = infoService.characteristics.first(where: { $0.type == .name })
        #expect(nameChar?.iid == 2)
    }

    @Test("bridge accessory information has 6 characteristics at iids 2–7")
    func bridgeInfoCharacteristicIIDs() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        let infoService = db[0].services[0]
        let iids = infoService.characteristics.map(\.iid).sorted()
        #expect(iids == [2, 3, 4, 5, 6, 7])
    }

    @Test("bridge accessory information characteristic types match expected order")
    func bridgeInfoCharTypes() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        let chars = db[0].services[0].characteristics
        let types = chars.map(\.type)
        // accessoryInformation factory: name, manufacturer, model, serialNumber, firmwareRevision, identify
        #expect(types[0] == .name)
        #expect(types[1] == .manufacturer)
        #expect(types[2] == .model)
        #expect(types[3] == .serialNumber)
        #expect(types[4] == .firmwareRevision)
        #expect(types[5] == .identify)
    }

    // MARK: - Added Accessory IID Layout

    @Test("added accessory info service is at iid=1")
    func addedAccessoryInfoServiceIID() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let infoService = accessory.services[0]
        #expect(infoService.iid == 1)
        #expect(infoService.type == .accessoryInformation)
    }

    @Test("added accessory info service characteristics occupy iids 2–7")
    func addedAccessoryInfoCharIIDs() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let infoIIDs = accessory.services[0].characteristics.map(\.iid).sorted()
        #expect(infoIIDs == [2, 3, 4, 5, 6, 7])
    }

    @Test("added security system service is at iid=8")
    func addedSecuritySystemServiceIID() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let secSvc = accessory.services.first(where: { $0.type == .securitySystem })!
        #expect(secSvc.iid == 8)
    }

    @Test("added security system characteristics are at iids 9, 10, 11")
    func addedSecuritySystemCharIIDs() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let secSvc = accessory.services.first(where: { $0.type == .securitySystem })!
        let iids = secSvc.characteristics.map(\.iid).sorted()
        #expect(iids == [9, 10, 11])
    }

    @Test("added accessory has no duplicate IIDs")
    func noDuplicateIIDs() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!

        var allIIDs: [UInt64] = []
        for service in accessory.services {
            allIIDs.append(service.iid)
            allIIDs.append(contentsOf: service.characteristics.map(\.iid))
        }
        let uniqueIIDs = Set(allIIDs)
        #expect(allIIDs.count == uniqueIIDs.count, "Found duplicate IIDs: \(allIIDs)")
    }

    @Test("second added service starts at correct iid after first service")
    func twoServicesIIDLayout() async throws {
        let bridge = makeBridge()
        let garageDoor = HAPService.garageDoorOpener(startIID: 1)
        let securitySystem = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Combined", manufacturer: "Acumen", model: "C1",
                                serialNumber: "003", firmwareRevision: "1.0.0"),
            services: [garageDoor, securitySystem]
        )
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!

        // info: iid=1, chars iid=2..7
        // garageDoor: iid=8, chars iid=9,10,11
        // securitySystem: iid=12, chars iid=13,14,15
        let garageSvc = accessory.services.first(where: { $0.type == .garageDoorOpener })!
        let secSvc = accessory.services.first(where: { $0.type == .securitySystem })!

        #expect(garageSvc.iid == 8)
        let garageIIDs = garageSvc.characteristics.map(\.iid).sorted()
        #expect(garageIIDs == [9, 10, 11])

        #expect(secSvc.iid == 12)
        let secIIDs = secSvc.characteristics.map(\.iid).sorted()
        #expect(secIIDs == [13, 14, 15])
    }

    @Test("two accessories get independent IID spaces (no cross-accessory collision)")
    func twoAccessoriesIndependentIIDs() async throws {
        let bridge = makeBridge()

        let aid1 = try await bridge.addAccessory(
            info: AccessoryInfo(name: "A1", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: [HAPService.securitySystem(startIID: 1)]
        )
        let aid2 = try await bridge.addAccessory(
            info: AccessoryInfo(name: "A2", manufacturer: "M", model: "M", serialNumber: "2", firmwareRevision: "1.0"),
            services: [HAPService.garageDoorOpener(startIID: 1)]
        )

        let db = await bridge.accessoryDatabase()
        let acc1 = db.first(where: { $0.aid == aid1 })!
        let acc2 = db.first(where: { $0.aid == aid2 })!

        // Each accessory's IID space is independent — both should have services at iid=8
        let secSvc = acc1.services.first(where: { $0.type == .securitySystem })!
        let garageSvc = acc2.services.first(where: { $0.type == .garageDoorOpener })!
        #expect(secSvc.iid == 8)
        #expect(garageSvc.iid == 8)
    }

    // MARK: - JSON Encoding

    @Test("accessory database JSON includes iid for every service")
    func jsonIncludesServiceIIDs() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [securityService]
        )

        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let charProtocol = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: PairingStateMachine(
                setupCode: "03145154",
                identity: identity,
                pairingStore: store,
                deviceID: "AA:BB:CC:DD:EE:FF"
            ),
            pairVerifyStateMachine: PairVerifyStateMachine(
                identity: identity,
                pairingStore: store,
                deviceID: "AA:BB:CC:DD:EE:FF"
            ),
            pairingStore: store,
            identity: identity
        )

        let response = try await charProtocol.handleGetAccessories()

        let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let accessories = json["accessories"] as! [[String: Any]]

        for accessory in accessories {
            let services = accessory["services"] as! [[String: Any]]
            for service in services {
                let iid = service["iid"]
                #expect(iid != nil, "Service missing 'iid' in accessory \(accessory["aid"] ?? "?")")
            }
        }

        // Verify the specific IIDs we expect
        let addedAccessory = accessories.first(where: { ($0["aid"] as? Int) == Int(aid) })!
        let services = addedAccessory["services"] as! [[String: Any]]
        let serviceIIDs = services.compactMap { $0["iid"] as? Int }.sorted()
        #expect(serviceIIDs.contains(1))  // info service
        #expect(serviceIIDs.contains(8))  // security system service
    }

    @Test("accessory database JSON IIDs match bridge internal state")
    func jsonIIDsMatchBridgeState() async throws {
        let bridge = makeBridge()
        let aid = try await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "Acumen", model: "P1",
                                serialNumber: "002", firmwareRevision: "1.0.0"),
            services: [HAPService.securitySystem(startIID: 1)]
        )

        // Get IIDs from bridge directly
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        var bridgeServiceIIDs: [UInt64] = []
        var bridgeCharIIDs: [UInt64] = []
        for service in accessory.services {
            bridgeServiceIIDs.append(service.iid)
            bridgeCharIIDs.append(contentsOf: service.characteristics.map(\.iid))
        }

        // Get IIDs from JSON
        let identity2 = HAPIdentity()
        let store2 = InMemoryPairingStore()
        let charProtocol = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: PairingStateMachine(
                setupCode: "03145154",
                identity: identity2,
                pairingStore: store2,
                deviceID: "AA:BB:CC:DD:EE:FF"
            ),
            pairVerifyStateMachine: PairVerifyStateMachine(
                identity: identity2,
                pairingStore: store2,
                deviceID: "AA:BB:CC:DD:EE:FF"
            ),
            pairingStore: store2,
            identity: identity2
        )
        let response = try await charProtocol.handleGetAccessories()

        let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let accessories = json["accessories"] as! [[String: Any]]
        let jsonAccessory = accessories.first(where: { ($0["aid"] as? Int) == Int(aid) })!
        let jsonServices = jsonAccessory["services"] as! [[String: Any]]

        var jsonServiceIIDs: [Int] = []
        var jsonCharIIDs: [Int] = []
        for service in jsonServices {
            if let iid = service["iid"] as? Int { jsonServiceIIDs.append(iid) }
            let chars = service["characteristics"] as! [[String: Any]]
            for char in chars {
                if let iid = char["iid"] as? Int { jsonCharIIDs.append(iid) }
            }
        }

        #expect(jsonServiceIIDs.sorted() == bridgeServiceIIDs.sorted().map(Int.init))
        #expect(jsonCharIIDs.sorted() == bridgeCharIIDs.sorted().map(Int.init))
    }
}
