// CryptoIntTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCrypto

@Suite("CryptoInt Tests")
struct CryptoIntTests {

    // MARK: - Basic Operations

    @Test("init from Data round-trip")
    func dataRoundTrip() {
        let original = Data([0x01, 0x00, 0xFF, 0xAB])
        let ci = CryptoInt(original)
        let result = ci.data
        #expect(result == original)
    }

    @Test("init from zero Data")
    func zeroData() {
        let ci = CryptoInt(Data([0x00]))
        #expect(ci.isZero)
        #expect(ci.data == Data([0x00]))
    }

    @Test("init from empty Data")
    func emptyData() {
        let ci = CryptoInt(Data())
        #expect(ci.isZero)
    }

    @Test("init from UInt64")
    func fromUInt64() {
        let ci = CryptoInt(256)
        #expect(ci.data == Data([0x01, 0x00]))
    }

    @Test("addition")
    func addition() {
        let a = CryptoInt(100)
        let b = CryptoInt(200)
        let sum = a + b
        #expect(sum == CryptoInt(300))
    }

    @Test("subtraction")
    func subtraction() {
        let a = CryptoInt(300)
        let b = CryptoInt(100)
        let diff = a - b
        #expect(diff == CryptoInt(200))
    }

    @Test("multiplication")
    func multiplication() {
        let a = CryptoInt(12345)
        let b = CryptoInt(67890)
        let product = a * b
        #expect(product == CryptoInt(838102050))
    }

    @Test("modulo")
    func modulo() {
        let a = CryptoInt(1000)
        let b = CryptoInt(7)
        let result = a % b
        #expect(result == CryptoInt(6))
    }

    @Test("modPow with small known values")
    func modPowSmall() {
        let result = CryptoInt.modPow(base: CryptoInt(2), exponent: CryptoInt(10), modulus: CryptoInt(1000))
        #expect(result == CryptoInt(24))
    }

    @Test("modPow with Fermat's little theorem")
    func modPowFermat() {
        let result = CryptoInt.modPow(base: CryptoInt(3), exponent: CryptoInt(100), modulus: CryptoInt(97))
        #expect(result == CryptoInt(81))
    }

    @Test("comparison operators")
    func comparison() {
        let a = CryptoInt(100)
        let b = CryptoInt(200)
        #expect(a < b)
        #expect(!(b < a))
        #expect(a == a)
        #expect(!(a == b))
    }

    @Test("paddedData preserves correct length")
    func paddedData() {
        let ci = CryptoInt(0xFF)
        let padded = ci.paddedData(to: 4)
        #expect(padded.count == 4)
        #expect(padded == Data([0x00, 0x00, 0x00, 0xFF]))
    }

    @Test("large data round-trip (384 bytes)")
    func largeDataRoundTrip() {
        var bytes = [UInt8](repeating: 0, count: 384)
        bytes[0] = 0x01
        for i in 1 ..< 384 { bytes[i] = UInt8(i % 256) }
        let original = Data(bytes)
        let ci = CryptoInt(original)
        let result = ci.data
        #expect(result == original)
    }

    // MARK: - Cross-Validation: BigInt vs CryptoInt

    @Test("cross-validate: modPow g^x mod N with SRP prime")
    func crossValidateModPow() {
        // Deterministic x from a known hash
        let xData = Data(repeating: 0xAB, count: 64)

        let biX = BigInt(xData)
        let ciX = CryptoInt(xData)

        let biN = SRPConstants_BigInt.N
        let ciN = SRPConstants.N

        let biG = SRPConstants_BigInt.g
        let ciG = SRPConstants.g

        let biResult = BigInt.modPow(base: biG, exponent: biX, modulus: biN)
        let ciResult = CryptoInt.modPow(base: ciG, exponent: ciX, modulus: ciN)

        let biData = biResult.paddedData(to: 384)
        let ciData = ciResult.paddedData(to: 384)

        #expect(
            biData == ciData,
            "BigInt and CryptoInt produce different g^x mod N — confirms BigInt arithmetic bug"
        )
    }

    @Test("cross-validate: k * v mod N (3072-bit multiply + modulo)")
    func crossValidateKV() {
        let salt = Data(repeating: 0x42, count: 16)
        let password = "03145154"

        // Compute x
        let x = computeX_BigInt(salt: salt, password: password)
        let xCI = SRPServer.computeX(salt: salt, password: password)

        // Compute v = g^x mod N
        let vBI = BigInt.modPow(
            base: SRPConstants_BigInt.g,
            exponent: x,
            modulus: SRPConstants_BigInt.N
        )
        let vCI = CryptoInt.modPow(
            base: SRPConstants.g,
            exponent: xCI,
            modulus: SRPConstants.N
        )

        // Compare verifiers
        let vBIData = vBI.paddedData(to: 384)
        let vCIData = vCI.paddedData(to: 384)
        #expect(
            vBIData == vCIData,
            "Verifier v = g^x mod N differs — BigInt modPow is incorrect"
        )

        // Compute k * v mod N
        let kvBI = (SRPConstants_BigInt.k * vBI) % SRPConstants_BigInt.N
        let kvCI = (SRPConstants.k * vCI) % SRPConstants.N

        let kvBIData = kvBI.paddedData(to: 384)
        let kvCIData = kvCI.paddedData(to: 384)
        #expect(
            kvBIData == kvCIData,
            "k*v mod N differs — BigInt multiplication or modulo is incorrect"
        )
    }

    @Test("cross-validate: full SRP shared secret S")
    func crossValidateFullSRP() {
        let salt = Data(repeating: 0x42, count: 16)
        let password = "03145154"
        let serverKey = Data(repeating: 0x11, count: 32)
        let clientKey = Data(repeating: 0x22, count: 32)

        // CryptoInt path (via SRPServer/SRPClient)
        let server = SRPServer(salt: salt, setupCode: password, serverPrivateKey: serverKey)
        let client = SRPClient(clientPrivateKey: clientKey)

        let clientResult = try! client.processServerChallenge(
            serverPublicKey: server.serverPublicKey,
            salt: salt,
            setupCode: password
        )
        let serverResult = try! server.processClientProof(
            clientPublicKey: client.clientPublicKey,
            clientProof: clientResult.clientProof
        )

        // BigInt path (manual computation)
        let xBI = computeX_BigInt(salt: salt, password: password)
        let vBI = BigInt.modPow(
            base: SRPConstants_BigInt.g,
            exponent: xBI,
            modulus: SRPConstants_BigInt.N
        )
        let bBI = BigInt(serverKey)
        let gbBI = BigInt.modPow(
            base: SRPConstants_BigInt.g,
            exponent: bBI,
            modulus: SRPConstants_BigInt.N
        )
        let kvBI = (SRPConstants_BigInt.k * vBI) % SRPConstants_BigInt.N
        let B_BI = (kvBI + gbBI) % SRPConstants_BigInt.N

        let aBI = BigInt(clientKey)
        let A_BI = BigInt.modPow(
            base: SRPConstants_BigInt.g,
            exponent: aBI,
            modulus: SRPConstants_BigInt.N
        )

        // u = SHA512(pad(A) | pad(B))
        let paddedA_BI = A_BI.paddedData(to: 384)
        let paddedB_BI = B_BI.paddedData(to: 384)
        var uHasher = SHA512()
        uHasher.update(data: paddedA_BI)
        uHasher.update(data: paddedB_BI)
        let uBI = BigInt(Data(uHasher.finalize()))

        // S_server = (A * v^u)^b mod N
        let vuBI = BigInt.modPow(base: vBI, exponent: uBI, modulus: SRPConstants_BigInt.N)
        let avuBI = (A_BI * vuBI) % SRPConstants_BigInt.N
        let S_BI = BigInt.modPow(base: avuBI, exponent: bBI, modulus: SRPConstants_BigInt.N)
        let K_BI = Data(SHA512.hash(data: S_BI.paddedData(to: 384)))

        // Compare session keys
        #expect(
            K_BI == serverResult.sessionKey,
            "BigInt-computed session key differs from CryptoInt — confirms BigInt arithmetic bug"
        )
    }

    // MARK: - BigInt Helpers (reproduce SRP constants using BigInt)

    private func computeX_BigInt(salt: Data, password: String) -> BigInt {
        var innerHasher = SHA512()
        innerHasher.update(data: Data("Pair-Setup".utf8))
        innerHasher.update(data: Data(":".utf8))
        innerHasher.update(data: Data(password.utf8))
        let innerHash = Data(innerHasher.finalize())

        var outerHasher = SHA512()
        outerHasher.update(data: salt)
        outerHasher.update(data: innerHash)
        return BigInt(Data(outerHasher.finalize()))
    }
}

// BigInt-based SRP constants for cross-validation.
private enum SRPConstants_BigInt {
    static let N: BigInt = {
        let hex = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08\
        8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B\
        302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9\
        A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6\
        49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8\
        FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D\
        670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C\
        180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D\
        04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D\
        B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D22\
        61AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200\
        CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BF\
        CE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """
        return BigInt(Data(hexString: hex)!)
    }()

    static let g = BigInt(5)

    static let k: BigInt = {
        let nData = N.paddedData(to: 384)
        let gData = g.paddedData(to: 384)
        var hasher = SHA512()
        hasher.update(data: nData)
        hasher.update(data: gData)
        return BigInt(Data(hasher.finalize()))
    }()
}

import Crypto
