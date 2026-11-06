// ControllerPermissionTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
import HAPCrypto
@testable import HAPTransport

struct ControllerPermissionTests {
    private func handler(bridge: HAPBridge, store: InMemoryPairingStore, controller: HAPControllerSimulator,
                         identity: HAPIdentity, connectionID: Int = 1) async throws -> CharacteristicProtocol {
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "00:00:00:00:00:01")
        _ = try await runPairVerify(controller: controller, stateMachine: verify, accessoryLTPK: identity.publicKeyData)
        return CharacteristicProtocol(bridge: bridge,
            pairingStateMachine: PairingStateMachine(setupCode: AccessoryIdentity.generateSetupCode(), identity: identity,
                                                     pairingStore: store, deviceID: "00:00:00:00:00:01"),
            pairVerifyStateMachine: verify, pairingStore: store, identity: identity, connectionID: connectionID)
    }

    @Test func onlyAdminCanManagePairingsAndLastAdminRemovalClearsAll() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let admin = HAPControllerSimulator(pairingID: "admin")
        let regular = HAPControllerSimulator(pairingID: "regular")
        try await store.store(controllerIdentifier: admin.pairingID, publicKey: admin.identity.publicKeyData)
        let bridge = HAPBridge(info: AccessoryInfo(name: "Bridge", manufacturer: "Virtual", model: "Test", serialNumber: "test", firmwareRevision: "1"))
        let adminHandler = try await handler(bridge: bridge, store: store, controller: admin, identity: identity)
        func request(_ method: UInt8, extra: [TLV8.Item] = []) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/pairings", body: TLV8.encode([
                (TLV8Type.state.rawValue, Data([1])), (TLV8Type.method.rawValue, Data([method]))] + extra))
        }
        let response = try await adminHandler.handleRequest(request(3, extra: [
            (TLV8Type.identifier.rawValue, Data(regular.pairingID.utf8)),
            (TLV8Type.publicKey.rawValue, regular.identity.publicKeyData), (TLV8Type.permissions.rawValue, Data([0]))]))
        #expect(try TLV8.decode(response.body).contains { $0.type == TLV8Type.error.rawValue } == false)
        #expect(await store.permission(for: "regular") == .regular)
        let list = try await adminHandler.handleRequest(request(5))
        #expect(try TLV8.decode(list.body).filter { $0.type == TLV8Type.permissions.rawValue }.map(\.value) == [Data([1]), Data([0])])
        let regularHandler = try await handler(bridge: bridge, store: store, controller: regular, identity: identity, connectionID: 2)
        for method: UInt8 in [3, 4, 5] {
            let denied = try await regularHandler.handleRequest(request(method))
            #expect(try TLV8.decode(denied.body).contains { $0.type == TLV8Type.error.rawValue && $0.value == Data([2]) })
        }
        let changedKey = try await adminHandler.handleRequest(request(3, extra: [
            (TLV8Type.identifier.rawValue, Data(regular.pairingID.utf8)),
            (TLV8Type.publicKey.rawValue, HAPIdentity().publicKeyData), (TLV8Type.permissions.rawValue, Data([1]))]))
        #expect(try TLV8.decode(changedKey.body).contains { $0.type == TLV8Type.error.rawValue })
        _ = try await adminHandler.handleRequest(request(4, extra: [(TLV8Type.identifier.rawValue, Data(admin.pairingID.utf8))]))
        #expect(await store.isPaired == false)
        #expect(try await regularHandler.handleRequest(HTTPRequest(method: "GET", path: "/accessories")).statusCode == 470)
    }

    @Test func timedWritesRequireUnexpiredConnectionScopedOneShotPID() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let controller = HAPControllerSimulator()
        try await store.store(controllerIdentifier: controller.pairingID, publicKey: controller.identity.publicKeyData)
        let bridge = HAPBridge(info: AccessoryInfo(name: "Bridge", manufacturer: "Virtual", model: "Test", serialNumber: "test", firmwareRevision: "1"))
        let service = HAPService(type: .switch, characteristics: [HAPCharacteristic(iid: 1, type: .on, value: .bool(false),
                                                                                  permissions: [.read, .write, .notify, .timedWrite], format: .bool)])
        try await bridge.addAccessory(info: AccessoryInfo(name: "Switch", manufacturer: "Virtual", model: "Test", serialNumber: "s", firmwareRevision: "1"), services: [service], aid: 2)
        let iid = try #require(await bridge.accessoryDatabase().last?.services.last?.characteristics.first?.iid)
        let first = try await handler(bridge: bridge, store: store, controller: controller, identity: identity)
        let second = try await handler(bridge: bridge, store: store, controller: controller, identity: identity, connectionID: 2)
        func write(_ pid: Int? = nil) throws -> HTTPRequest {
            var json: [String: Any] = ["characteristics": [["aid": 2, "iid": iid, "value": true]]]
            if let pid { json["pid"] = pid }
            return HTTPRequest(method: "PUT", path: "/characteristics", body: try JSONSerialization.data(withJSONObject: json))
        }
        func prepare(ttl: Int = 1000) -> HTTPRequest {
            HTTPRequest(method: "PUT", path: "/prepare", body: Data("{\"ttl\":\(ttl),\"pid\":7}".utf8))
        }
        #expect(try await first.handleRequest(write()).statusCode == 207)
        #expect(try await first.handleRequest(prepare()).statusCode == 200)
        #expect(try await second.handleRequest(write(7)).statusCode == 207)
        #expect(try await first.handleRequest(write(8)).statusCode == 207)
        // A failed PID attempt also consumes the preparation.
        #expect(try await first.handleRequest(write(7)).statusCode == 207)
        _ = try await first.handleRequest(prepare())
        #expect(try await first.handleRequest(write(7)).statusCode == 204)
        #expect(try await first.handleRequest(write(7)).statusCode == 207)
        _ = try await first.handleRequest(prepare(ttl: 1))
        try await Task.sleep(for: .milliseconds(10))
        let expired = try await first.handleRequest(write(7))
        let json = try #require(JSONSerialization.jsonObject(with: expired.body) as? [String: [[String: Int]]])
        #expect(json["characteristics"]?.first?["status"] == HAPStatus.operationTimedOut.rawValue)
    }
}
