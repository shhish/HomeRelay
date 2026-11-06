// HAPEncryptionTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import Testing
@testable import HAPCrypto

@Suite("HAPEncryption Tests")
struct HAPEncryptionTests {

    @Test("encrypt and decrypt round-trip")
    func encryptDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Hello, HAP!".utf8)
        let nonce = HAPEncryption.buildNonce(counter: 0)

        let ciphertext = try HAPEncryption.encrypt(plaintext: plaintext, key: key, nonce: nonce)
        let decrypted = try HAPEncryption.decrypt(ciphertext: ciphertext, key: key, nonce: nonce)

        #expect(decrypted == plaintext)
    }

    @Test("nonce from counter has correct format")
    func nonceFromCounter() {
        let nonce = HAPEncryption.buildNonce(counter: 42)
        #expect(nonce.count == 12)
        // First 4 bytes are zero
        #expect(nonce[0] == 0)
        #expect(nonce[1] == 0)
        #expect(nonce[2] == 0)
        #expect(nonce[3] == 0)
        // Next 8 bytes are 42 in little-endian
        #expect(nonce[4] == 42)
        #expect(nonce[5] == 0)
    }

    @Test("nonce from string PS-Msg05")
    func nonceFromString() {
        let nonce = HAPEncryption.buildNonce(from: "PS-Msg05")
        #expect(nonce.count == 12)
        // First 4 bytes zero
        #expect(nonce[0 ..< 4] == Data(repeating: 0, count: 4))
        // Next 8 bytes are "PS-Msg05" ASCII
        #expect(nonce[4] == 0x50)  // 'P'
        #expect(nonce[5] == 0x53)  // 'S'
        #expect(nonce[11] == 0x35) // '5'
    }

    @Test("tamper detection — modified ciphertext produces different plaintext or throws")
    func tamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Sensitive data".utf8)
        let nonce = HAPEncryption.buildNonce(counter: 1)

        let ciphertext = try HAPEncryption.encrypt(plaintext: plaintext, key: key, nonce: nonce)

        // Tamper with the auth tag (last 16 bytes) to ensure decryption fails
        var tampered = ciphertext
        tampered[tampered.count - 1] ^= 0xFF

        // ChaChaPoly.open should throw on auth failure
        do {
            let result = try HAPEncryption.decrypt(ciphertext: tampered, key: key, nonce: nonce)
            // If somehow it doesn't throw, the plaintext must differ
            #expect(result != plaintext)
        } catch {
            // Expected path: authentication tag mismatch
        }
    }

    @Test("different counters produce different ciphertexts")
    func differentCounters() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Same data".utf8)

        let ct1 = try HAPEncryption.encrypt(
            plaintext: plaintext, key: key,
            nonce: HAPEncryption.buildNonce(counter: 0)
        )
        let ct2 = try HAPEncryption.encrypt(
            plaintext: plaintext, key: key,
            nonce: HAPEncryption.buildNonce(counter: 1)
        )

        #expect(ct1 != ct2)
    }
}
