// PairingStateMachineTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
import HAPCrypto
@testable import HAPTransport

@Suite("PairingStateMachine Tests")
struct PairingStateMachineTests {

    @Test("M1 returns M2 with state=2, public key, and salt")
    func m1ReturnsM2() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let sm = PairingStateMachine(setupCode: "03145154", identity: identity, pairingStore: store, deviceID: "AA:BB:CC:DD:EE:FF")

        // Build M1
        let m1 = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x01])),
            (type: TLV8Type.method.rawValue, value: Data([0x00])),
        ])

        let response = try await sm.handleRequest(m1)
        let items = try TLV8.decode(response)

        // Should contain state=2
        let stateItem = items.first(where: { $0.type == TLV8Type.state.rawValue })
        #expect(stateItem?.value == Data([0x02]))

        // Should contain public key (384 bytes for SRP 3072-bit)
        let pkItem = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })
        #expect(pkItem?.value.count == 384)

        // Should contain salt (16 bytes)
        let saltItem = items.first(where: { $0.type == TLV8Type.salt.rawValue })
        #expect(saltItem?.value.count == 16)
    }

    @Test("invalid M1 method produces error TLV")
    func invalidM1Method() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let sm = PairingStateMachine(setupCode: "03145154", identity: identity, pairingStore: store, deviceID: "AA:BB:CC:DD:EE:FF")

        // M1 with method != 0
        let m1 = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x01])),
            (type: TLV8Type.method.rawValue, value: Data([0x05])),
        ])

        let response = try await sm.handleRequest(m1)
        let items = try TLV8.decode(response)

        let stateItem = items.first(where: { $0.type == TLV8Type.state.rawValue })
        #expect(stateItem?.value == Data([0x02]))

        let errorItem = items.first(where: { $0.type == TLV8Type.error.rawValue })
        #expect(errorItem != nil)
    }

    @Test("setup code with dashes is equivalent to digits-only")
    func setupCodeDashesStripped() async throws {
        let identity = HAPIdentity()

        // Accessory initialized with "031-45-154" (as-stored in config)
        let storeWithDashes = InMemoryPairingStore()
        let smWithDashes = PairingStateMachine(
            setupCode: "031-45-154",
            identity: identity, pairingStore: storeWithDashes,
            deviceID: "AA:BB:CC:DD:EE:FF"
        )

        // Accessory initialized with "03145154" (digits-only)
        let storeDigits = InMemoryPairingStore()
        let smDigits = PairingStateMachine(
            setupCode: "03145154",
            identity: identity, pairingStore: storeDigits,
            deviceID: "AA:BB:CC:DD:EE:FF"
        )

        // Both should advance to M2 without error
        let m1 = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x01])),
            (type: TLV8Type.method.rawValue, value: Data([0x00])),
        ])

        let r1 = try await smWithDashes.handleRequest(m1)
        let r2 = try await smDigits.handleRequest(m1)

        let state1 = try TLV8.decode(r1).first(where: { $0.type == TLV8Type.state.rawValue })?.value
        let state2 = try TLV8.decode(r2).first(where: { $0.type == TLV8Type.state.rawValue })?.value
        #expect(state1 == Data([0x02]))
        #expect(state2 == Data([0x02]))
    }

    @Test("out-of-order state produces error")
    func outOfOrderState() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let sm = PairingStateMachine(setupCode: "03145154", identity: identity, pairingStore: store, deviceID: "AA:BB:CC:DD:EE:FF")

        // Send M3 without M1 first
        let m3 = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x03])),
            (type: TLV8Type.publicKey.rawValue, value: Data(repeating: 0, count: 384)),
            (type: TLV8Type.proof.rawValue, value: Data(repeating: 0, count: 64)),
        ])

        let response = try await sm.handleRequest(m3)
        let items = try TLV8.decode(response)

        let errorItem = items.first(where: { $0.type == TLV8Type.error.rawValue })
        #expect(errorItem != nil)
    }
}
