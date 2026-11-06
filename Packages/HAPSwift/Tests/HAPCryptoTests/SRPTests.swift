// SRPTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import Testing
@testable import HAPCrypto

@Suite("SRP Tests")
struct SRPTests {

    @Test("full client-server handshake — both derive same session key")
    func fullHandshake() throws {
        let setupCode = "03145154"

        let server = SRPServer(setupCode: setupCode)
        let client = SRPClient()

        let (clientProof, expectedServerProof, clientSessionKey) = try client.processServerChallenge(
            serverPublicKey: server.serverPublicKey,
            salt: server.salt,
            setupCode: setupCode
        )

        let (serverProof, serverSessionKey) = try server.processClientProof(
            clientPublicKey: client.clientPublicKey,
            clientProof: clientProof
        )

        #expect(clientSessionKey == serverSessionKey)
        #expect(serverProof == expectedServerProof)
    }

    @Test("invalid client public key A=0 is rejected")
    func invalidClientPublicKeyZero() throws {
        let server = SRPServer(setupCode: "03145154")
        let zeroKey = Data(repeating: 0, count: 384)
        let fakeProof = Data(repeating: 0, count: 64)

        #expect(throws: HAPCryptoError.self) {
            _ = try server.processClientProof(
                clientPublicKey: zeroKey,
                clientProof: fakeProof
            )
        }
    }

    @Test("wrong client proof is rejected")
    func wrongClientProof() throws {
        let setupCode = "03145154"
        let server = SRPServer(setupCode: setupCode)
        let client = SRPClient()

        let (clientProof, _, _) = try client.processServerChallenge(
            serverPublicKey: server.serverPublicKey,
            salt: server.salt,
            setupCode: setupCode
        )

        // Tamper with proof
        var tamperedProof = clientProof
        tamperedProof[0] ^= 0xFF

        #expect(throws: HAPCryptoError.self) {
            _ = try server.processClientProof(
                clientPublicKey: client.clientPublicKey,
                clientProof: tamperedProof
            )
        }
    }

    @Test("wrong password produces proof mismatch")
    func wrongPassword() throws {
        let server = SRPServer(setupCode: "03145154")
        let client = SRPClient()

        let (clientProof, _, _) = try client.processServerChallenge(
            serverPublicKey: server.serverPublicKey,
            salt: server.salt,
            setupCode: "99999999"  // Wrong password
        )

        #expect(throws: HAPCryptoError.self) {
            _ = try server.processClientProof(
                clientPublicKey: client.clientPublicKey,
                clientProof: clientProof
            )
        }
    }

    @Test("deterministic handshake with known private keys")
    func deterministicHandshake() throws {
        let setupCode = "03145154"
        let salt = Data(repeating: 0xAB, count: 16)
        let serverPrivateKey = Data(repeating: 0x01, count: 32)
        let clientPrivateKey = Data(repeating: 0x02, count: 32)

        let server = SRPServer(salt: salt, setupCode: setupCode, serverPrivateKey: serverPrivateKey)
        let client = SRPClient(clientPrivateKey: clientPrivateKey)

        let (clientProof, expectedServerProof, clientSessionKey) = try client.processServerChallenge(
            serverPublicKey: server.serverPublicKey,
            salt: salt,
            setupCode: setupCode
        )

        let (serverProof, serverSessionKey) = try server.processClientProof(
            clientPublicKey: client.clientPublicKey,
            clientProof: clientProof
        )

        #expect(clientSessionKey == serverSessionKey)
        #expect(serverProof == expectedServerProof)

        // Session key should be deterministic with fixed inputs
        #expect(serverSessionKey.count == 64)  // SHA-512 output
    }

    // MARK: - RFC 2945 M1 Correctness

    @Test("H(g) in M1 uses minimal 1-byte representation per RFC 2945")
    func hgUsesMinimalRepresentation() {
        // RFC 2945 specifies H(N) XOR H(g) using the minimal big-endian byte
        // representation of each value — NOT a padded form.
        //
        // For g = 5, the minimal representation is [0x05] (1 byte).
        // Padding g to 384 bytes before hashing (as RFC 5054 does for k) produces
        // a completely different SHA-512 output, causing M1 to mismatch against any
        // correct RFC 2945 implementation (including iOS).
        #expect(SRPConstants.g.data == Data([0x05]))

        let hashOfRaw    = Data(SHA512.hash(data: SRPConstants.g.data))
        let hashOfPadded = Data(SHA512.hash(data: SRPConstants.g.paddedData(to: 384)))
        // The two computations must differ — using paddedData for H(g) is wrong.
        #expect(hashOfRaw != hashOfPadded)
    }

    @Test("computeM1 result differs between raw-g and padded-g inputs (regression guard)")
    func computeM1RawVsPadded() {
        // Build a minimal set of inputs (all zeros is fine — we're testing the
        // formula structure, not a real handshake).
        let dummyA    = Data(repeating: 0x01, count: 384)
        let dummyB    = Data(repeating: 0x02, count: 384)
        let dummyK    = Data(repeating: 0x03, count: 64)
        let dummySalt = Data(repeating: 0x04, count: 16)

        // Correct M1 (uses raw g = [0x05]).
        let m1Correct = SRPServer.computeM1(A: dummyA, B: dummyB, K: dummyK, salt: dummySalt)

        // Simulate what the buggy padded-g version would produce.
        let nData = SRPConstants.N.data
        let gDataPadded = SRPConstants.g.paddedData(to: 384)   // the old, wrong path
        let hashN = Data(SHA512.hash(data: nData))
        let hashGPadded = Data(SHA512.hash(data: gDataPadded))
        var xorNG = Data(count: 64)
        for i in 0 ..< 64 { xorNG[i] = hashN[i] ^ hashGPadded[i] }
        let hashI = Data(SHA512.hash(data: Data(SRPConstants.username.utf8)))
        var hasher = SHA512()
        hasher.update(data: xorNG)
        hasher.update(data: hashI)
        hasher.update(data: dummySalt)
        hasher.update(data: dummyA)
        hasher.update(data: dummyB)
        hasher.update(data: dummyK)
        let m1Buggy = Data(hasher.finalize())

        // The correct and buggy paths must produce different M1 values.
        // If this test fails, computeM1 has regressed to padding g.
        #expect(m1Correct != m1Buggy)
    }

    @Test("multiple handshakes produce different session keys")
    func differentKeysPerHandshake() throws {
        let setupCode = "03145154"

        let server1 = SRPServer(setupCode: setupCode)
        let client1 = SRPClient()
        let (proof1, _, key1) = try client1.processServerChallenge(
            serverPublicKey: server1.serverPublicKey,
            salt: server1.salt,
            setupCode: setupCode
        )
        let (_, serverKey1) = try server1.processClientProof(
            clientPublicKey: client1.clientPublicKey,
            clientProof: proof1
        )

        let server2 = SRPServer(setupCode: setupCode)
        let client2 = SRPClient()
        let (proof2, _, key2) = try client2.processServerChallenge(
            serverPublicKey: server2.serverPublicKey,
            salt: server2.salt,
            setupCode: setupCode
        )
        let (_, serverKey2) = try server2.processClientProof(
            clientPublicKey: client2.clientPublicKey,
            clientProof: proof2
        )

        #expect(key1 == serverKey1)
        #expect(key2 == serverKey2)
        #expect(key1 != key2)  // Different random keys each time
    }
}
