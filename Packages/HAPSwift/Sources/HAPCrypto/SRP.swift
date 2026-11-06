// SRP.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto

// MARK: - SRP Constants

enum SRPConstants {
    /// RFC 5054 3072-bit prime N.
    static let N: CryptoInt = {
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
        return CryptoInt(Data(hexString: hex)!)
    }()

    /// Generator g = 5.
    static let g = CryptoInt(5)

    /// k = SHA512(N | pad(g))
    static let k: CryptoInt = {
        let nData = N.paddedData(to: 384)
        let gData = g.paddedData(to: 384)
        var hasher = SHA512()
        hasher.update(data: nData)
        hasher.update(data: gData)
        let digest = Data(hasher.finalize())
        return CryptoInt(digest)
    }()

    /// Byte length of N (384 bytes for 3072-bit).
    static let paddedLength = 384

    /// Username for HAP pairing.
    static let username = "Pair-Setup"
}

// MARK: - SRPServer

public struct SRPServer: Sendable {
    public let salt: Data
    public let serverPublicKey: Data

    private let verifier: CryptoInt
    private let serverPrivateKey: CryptoInt
    private let serverPublicKeyBigInt: CryptoInt

    public init(setupCode: String) {
        let salt = SRPServer.generateSalt()
        let x = SRPServer.computeX(salt: salt, password: setupCode)
        let v = CryptoInt.modPow(base: SRPConstants.g, exponent: x, modulus: SRPConstants.N)

        // Generate server private key b
        let b = CryptoInt(generateRandomBytes(count: 32))

        // B = (k*v + g^b mod N) mod N
        let gb = CryptoInt.modPow(base: SRPConstants.g, exponent: b, modulus: SRPConstants.N)
        let kv = (SRPConstants.k * v) % SRPConstants.N
        let B = (kv + gb) % SRPConstants.N

        self.salt = salt
        self.verifier = v
        self.serverPrivateKey = b
        self.serverPublicKeyBigInt = B
        self.serverPublicKey = B.paddedData(to: SRPConstants.paddedLength)
    }

    /// Internal init for deterministic testing.
    init(salt: Data, setupCode: String, serverPrivateKey: Data) {
        let x = SRPServer.computeX(salt: salt, password: setupCode)
        let v = CryptoInt.modPow(base: SRPConstants.g, exponent: x, modulus: SRPConstants.N)

        let b = CryptoInt(serverPrivateKey)
        let gb = CryptoInt.modPow(base: SRPConstants.g, exponent: b, modulus: SRPConstants.N)
        let kv = (SRPConstants.k * v) % SRPConstants.N
        let B = (kv + gb) % SRPConstants.N

        self.salt = salt
        self.verifier = v
        self.serverPrivateKey = b
        self.serverPublicKeyBigInt = B
        self.serverPublicKey = B.paddedData(to: SRPConstants.paddedLength)
    }

    public func processClientProof(
        clientPublicKey clientPublicKeyData: Data,
        clientProof clientProofData: Data
    ) throws -> (serverProof: Data, sessionKey: Data) {
        let A = CryptoInt(clientPublicKeyData)

        // Reject A == 0 mod N
        guard !(A % SRPConstants.N).isZero else {
            throw HAPCryptoError.invalidPublicKey
        }

        // u = SHA512(pad(A) | pad(B))
        let paddedA = A.paddedData(to: SRPConstants.paddedLength)
        let paddedB = serverPublicKeyBigInt.paddedData(to: SRPConstants.paddedLength)
        var uHasher = SHA512()
        uHasher.update(data: paddedA)
        uHasher.update(data: paddedB)
        let u = CryptoInt(Data(uHasher.finalize()))

        // S = (A * v^u)^b mod N
        let vu = CryptoInt.modPow(base: verifier, exponent: u, modulus: SRPConstants.N)
        let avu = (A * vu) % SRPConstants.N
        let S = CryptoInt.modPow(base: avu, exponent: serverPrivateKey, modulus: SRPConstants.N)

        // K = SHA512(S)
        let sData = S.paddedData(to: SRPConstants.paddedLength)
        let K = Data(SHA512.hash(data: sData))

        // Verify M1
        let expectedM1 = SRPServer.computeM1(
            A: paddedA, B: paddedB, K: K, salt: salt
        )

        guard clientProofData == expectedM1 else {
            // Diagnostic dump — compare intermediate values against hap-nodejs to
            // identify the exact point of divergence.
            print("[SRP-DIAG] salt       = \(salt.hexString)")
            print("[SRP-DIAG] A (first8) = \(paddedA.prefix(8).hexString)")
            print("[SRP-DIAG] B (first8) = \(paddedB.prefix(8).hexString)")
            print("[SRP-DIAG] u (first8) = \(u.paddedData(to: 64).prefix(8).hexString)")
            print("[SRP-DIAG] S (first8) = \(sData.prefix(8).hexString)")
            print("[SRP-DIAG] K          = \(K.hexString)")
            print("[SRP-DIAG] expectedM1 = \(expectedM1.hexString)")
            print("[SRP-DIAG] receivedM1 = \(clientProofData.hexString)")
            throw HAPCryptoError.proofMismatch
        }

        // Compute M2 = SHA512(A | M1 | K)
        var m2Hasher = SHA512()
        m2Hasher.update(data: paddedA)
        m2Hasher.update(data: expectedM1)
        m2Hasher.update(data: K)
        let M2 = Data(m2Hasher.finalize())

        return (serverProof: M2, sessionKey: K)
    }

    // MARK: - Private Helpers

    private static func generateSalt() -> Data {
        generateRandomBytes(count: 16)
    }

    static func computeX(salt: Data, password: String) -> CryptoInt {
        // x = SHA512(salt | SHA512("Pair-Setup" | ":" | password))
        var innerHasher = SHA512()
        innerHasher.update(data: Data(SRPConstants.username.utf8))
        innerHasher.update(data: Data(":".utf8))
        innerHasher.update(data: Data(password.utf8))
        let innerHash = Data(innerHasher.finalize())

        var outerHasher = SHA512()
        outerHasher.update(data: salt)
        outerHasher.update(data: innerHash)
        let x = CryptoInt(Data(outerHasher.finalize()))
        return x
    }

    static func computeM1(A: Data, B: Data, K: Data, salt: Data) -> Data {
        // M1 = SHA512(SHA512(N) XOR SHA512(g) | SHA512(I) | s | A | B | K)
        // Per RFC 2945, H(N) and H(g) use the minimal (unpadded) big-endian
        // representation. N is a 3072-bit prime so its raw data is already 384
        // bytes. g = 5, so its raw data is a single byte [0x05] — NOT padded to
        // 384. (Contrast with k = H(N | pad(g)) per RFC 5054 where g IS padded.)
        let nData = SRPConstants.N.data   // 384 bytes — prime fills the full width
        let gData = SRPConstants.g.data   // [0x05] — minimal big-endian representation (NOT padded)

        let hashN = Data(SHA512.hash(data: nData))
        let hashG = Data(SHA512.hash(data: gData))

        var xorNG = Data(count: 64)
        for i in 0 ..< 64 {
            xorNG[i] = hashN[i] ^ hashG[i]
        }

        let hashI = Data(SHA512.hash(data: Data(SRPConstants.username.utf8)))

        var hasher = SHA512()
        hasher.update(data: xorNG)
        hasher.update(data: hashI)
        hasher.update(data: salt)
        hasher.update(data: A)
        hasher.update(data: B)
        hasher.update(data: K)
        return Data(hasher.finalize())
    }
}

// MARK: - SRPClient (for testing)

struct SRPClient: Sendable {
    let clientPublicKey: Data
    private let clientPrivateKey: CryptoInt
    private let clientPublicKeyBigInt: CryptoInt

    init() {
        let a = CryptoInt(generateRandomBytes(count: 32))
        let A = CryptoInt.modPow(base: SRPConstants.g, exponent: a, modulus: SRPConstants.N)

        self.clientPrivateKey = a
        self.clientPublicKeyBigInt = A
        self.clientPublicKey = A.paddedData(to: SRPConstants.paddedLength)
    }

    /// Internal init for deterministic testing.
    init(clientPrivateKey: Data) {
        let a = CryptoInt(clientPrivateKey)
        let A = CryptoInt.modPow(base: SRPConstants.g, exponent: a, modulus: SRPConstants.N)

        self.clientPrivateKey = a
        self.clientPublicKeyBigInt = A
        self.clientPublicKey = A.paddedData(to: SRPConstants.paddedLength)
    }

    func processServerChallenge(
        serverPublicKey serverPublicKeyData: Data,
        salt: Data,
        setupCode: String
    ) throws -> (clientProof: Data, serverProofExpected: Data, sessionKey: Data) {
        let B = CryptoInt(serverPublicKeyData)

        guard !(B % SRPConstants.N).isZero else {
            throw HAPCryptoError.invalidPublicKey
        }

        let paddedA = clientPublicKeyBigInt.paddedData(to: SRPConstants.paddedLength)
        let paddedB = B.paddedData(to: SRPConstants.paddedLength)

        // u = SHA512(pad(A) | pad(B))
        var uHasher = SHA512()
        uHasher.update(data: paddedA)
        uHasher.update(data: paddedB)
        let u = CryptoInt(Data(uHasher.finalize()))

        // x = SHA512(salt | SHA512(I:P))
        let x = SRPServer.computeX(salt: salt, password: setupCode)

        // S = (B - k * g^x)^(a + u * x) mod N
        let gx = CryptoInt.modPow(base: SRPConstants.g, exponent: x, modulus: SRPConstants.N)
        let kgx = (SRPConstants.k * gx) % SRPConstants.N

        // Handle B - kgx (might need to add N to keep positive)
        let base: CryptoInt
        if B > kgx {
            base = B - kgx
        } else {
            base = (B + SRPConstants.N) - kgx
        }

        let ux = (u * x) % SRPConstants.N
        let exp = (clientPrivateKey + ux) % SRPConstants.N
        let S = CryptoInt.modPow(base: base, exponent: exp, modulus: SRPConstants.N)

        // K = SHA512(S)
        let sData = S.paddedData(to: SRPConstants.paddedLength)
        let K = Data(SHA512.hash(data: sData))

        // M1 = SHA512(SHA512(N) XOR SHA512(g) | SHA512(I) | s | A | B | K)
        let M1 = SRPServer.computeM1(A: paddedA, B: paddedB, K: K, salt: salt)

        // M2 = SHA512(A | M1 | K)
        var m2Hasher = SHA512()
        m2Hasher.update(data: paddedA)
        m2Hasher.update(data: M1)
        m2Hasher.update(data: K)
        let M2 = Data(m2Hasher.finalize())

        return (clientProof: M1, serverProofExpected: M2, sessionKey: K)
    }
}

// MARK: - Cross-Platform Random

private func generateRandomBytes(count: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0 ..< count {
        bytes[i] = UInt8.random(in: 0 ... 255, using: &rng)
    }
    return Data(bytes)
}

// MARK: - Hex Data Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
