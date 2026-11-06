// HAPIdentityTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCrypto

@Suite("HAPIdentity Tests")
struct HAPIdentityTests {

    @Test("generate and sign")
    func generateAndSign() throws {
        let identity = HAPIdentity()
        let message = Data("test message".utf8)
        let signature = try identity.sign(message)

        let valid = try HAPIdentity.verify(
            signature: signature, data: message, publicKey: identity.publicKeyData
        )
        #expect(valid)
    }

    @Test("round-trip persistence")
    func roundTripPersistence() throws {
        let original = HAPIdentity()
        let privateKeyData = original.privateKeyData
        let restored = try HAPIdentity(privateKeyData: privateKeyData)
        #expect(original.publicKeyData == restored.publicKeyData)
    }

    @Test("verify with wrong message fails")
    func wrongMessage() throws {
        let identity = HAPIdentity()
        let signature = try identity.sign(Data("correct".utf8))

        let valid = try HAPIdentity.verify(
            signature: signature, data: Data("wrong".utf8), publicKey: identity.publicKeyData
        )
        #expect(!valid)
    }

    @Test("public key is 32 bytes")
    func publicKeySize() {
        let identity = HAPIdentity()
        #expect(identity.publicKeyData.count == 32)
    }

    @Test("invalid key data throws")
    func invalidKeyData() {
        #expect(throws: HAPCryptoError.self) {
            _ = try HAPIdentity(privateKeyData: Data([0x01, 0x02]))
        }
    }
}
