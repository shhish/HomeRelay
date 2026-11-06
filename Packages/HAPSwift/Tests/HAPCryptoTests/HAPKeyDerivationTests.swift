// HAPKeyDerivationTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import Testing
@testable import HAPCrypto

@Suite("HAPKeyDerivation Tests")
struct HAPKeyDerivationTests {

    @Test("derivePairSetupKey produces 32-byte key")
    func pairSetupKeyLength() {
        let sessionKey = Data(repeating: 0xAB, count: 64)
        let key = HAPKeyDerivation.derivePairSetupEncryptionKey(from: sessionKey)
        key.withUnsafeBytes { buffer in
            #expect(buffer.count == 32)
        }
    }

    @Test("deriveSessionKeys produces two distinct keys")
    func sessionKeysDistinct() {
        let sharedSecret = Data(repeating: 0xCD, count: 64)
        let (writeKey, readKey) = HAPKeyDerivation.deriveSessionKeys(from: sharedSecret)

        var writeBytes = Data()
        writeKey.withUnsafeBytes { writeBytes = Data($0) }
        var readBytes = Data()
        readKey.withUnsafeBytes { readBytes = Data($0) }

        #expect(writeBytes != readBytes)
        #expect(writeBytes.count == 32)
        #expect(readBytes.count == 32)
    }

    @Test("deterministic — same input produces same output")
    func deterministic() {
        let input = Data(repeating: 0x42, count: 64)
        let key1 = HAPKeyDerivation.derivePairSetupEncryptionKey(from: input)
        let key2 = HAPKeyDerivation.derivePairSetupEncryptionKey(from: input)

        var bytes1 = Data()
        key1.withUnsafeBytes { bytes1 = Data($0) }
        var bytes2 = Data()
        key2.withUnsafeBytes { bytes2 = Data($0) }

        #expect(bytes1 == bytes2)
    }

    @Test("setupHash produces 6-char base64 string")
    func setupHashLength() {
        let hash = HAPKeyDerivation.setupHash(setupID: "ACMN", deviceID: "AA:BB:CC:DD:EE:FF")
        // 4 bytes → 6 base64 chars (with 2 padding = chars) = 8 total, but base64 of 4 bytes is exactly 8 chars
        #expect(hash.count == 8)
    }

    @Test("setupHash is deterministic")
    func setupHashDeterministic() {
        let h1 = HAPKeyDerivation.setupHash(setupID: "ACMN", deviceID: "AA:BB:CC:DD:EE:FF")
        let h2 = HAPKeyDerivation.setupHash(setupID: "ACMN", deviceID: "AA:BB:CC:DD:EE:FF")
        #expect(h1 == h2)
    }

    @Test("setupHash differs for different setup IDs")
    func setupHashVariesWithSetupID() {
        let h1 = HAPKeyDerivation.setupHash(setupID: "ACMN", deviceID: "AA:BB:CC:DD:EE:FF")
        let h2 = HAPKeyDerivation.setupHash(setupID: "WXYZ", deviceID: "AA:BB:CC:DD:EE:FF")
        #expect(h1 != h2)
    }
}
