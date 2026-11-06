// BigIntTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCrypto

@Suite("BigInt Tests")
struct BigIntTests {

    @Test("init from Data round-trip")
    func dataRoundTrip() {
        let original = Data([0x01, 0x00, 0xFF, 0xAB])
        let bigint = BigInt(original)
        let result = bigint.data
        #expect(result == original)
    }

    @Test("init from zero Data")
    func zeroData() {
        let bigint = BigInt(Data([0x00]))
        #expect(bigint.isZero)
        #expect(bigint.data == Data([0x00]))
    }

    @Test("init from empty Data")
    func emptyData() {
        let bigint = BigInt(Data())
        #expect(bigint.isZero)
    }

    @Test("init from UInt64")
    func fromUInt64() {
        let bigint = BigInt(256)
        #expect(bigint.data == Data([0x01, 0x00]))
    }

    @Test("addition")
    func addition() {
        let a = BigInt(100)
        let b = BigInt(200)
        let sum = a + b
        #expect(sum == BigInt(300))
    }

    @Test("addition with carry across limbs")
    func additionWithCarry() {
        let a = BigInt(UInt64.max)
        let b = BigInt(1)
        let sum = a + b
        let expected = BigInt(Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(sum == expected)
    }

    @Test("subtraction")
    func subtraction() {
        let a = BigInt(300)
        let b = BigInt(100)
        let diff = a - b
        #expect(diff == BigInt(200))
    }

    @Test("multiplication")
    func multiplication() {
        let a = BigInt(12345)
        let b = BigInt(67890)
        let product = a * b
        // 12345 * 67890 = 838102050
        #expect(product == BigInt(838102050))
    }

    @Test("modulo")
    func modulo() {
        let a = BigInt(1000)
        let b = BigInt(7)
        let result = a % b
        // 1000 % 7 = 6
        #expect(result == BigInt(6))
    }

    @Test("modPow with small known values")
    func modPowSmall() {
        // 2^10 mod 1000 = 1024 mod 1000 = 24
        let result = BigInt.modPow(base: BigInt(2), exponent: BigInt(10), modulus: BigInt(1000))
        #expect(result == BigInt(24))
    }

    @Test("modPow with larger values")
    func modPowLarger() {
        // 3^100 mod 97 — by Fermat's little theorem, 3^96 ≡ 1 (mod 97), so 3^100 = 3^4 = 81
        let result = BigInt.modPow(base: BigInt(3), exponent: BigInt(100), modulus: BigInt(97))
        #expect(result == BigInt(81))
    }

    @Test("modInverse")
    func modInverse() {
        let a = BigInt(3)
        let m = BigInt(7)
        let inv = a.modInverse(m)
        // 3 * inv ≡ 1 (mod 7) → inv = 5 (3*5=15, 15%7=1)
        let product = (a * inv) % m
        #expect(product == BigInt(1))
    }

    @Test("modInverse larger")
    func modInverseLarger() {
        let a = BigInt(17)
        let m = BigInt(3120)
        let inv = a.modInverse(m)
        let product = (a * inv) % m
        #expect(product == BigInt(1))
    }

    @Test("comparison operators")
    func comparison() {
        let a = BigInt(100)
        let b = BigInt(200)
        #expect(a < b)
        #expect(!(b < a))
        #expect(a == a)
        #expect(!(a == b))
    }

    @Test("paddedData preserves correct length")
    func paddedData() {
        let bigint = BigInt(0xFF)
        let padded = bigint.paddedData(to: 4)
        #expect(padded.count == 4)
        #expect(padded == Data([0x00, 0x00, 0x00, 0xFF]))
    }

    @Test("large data round-trip (384 bytes)")
    func largeDataRoundTrip() {
        var bytes = [UInt8](repeating: 0, count: 384)
        bytes[0] = 0x01  // Leading non-zero byte
        for i in 1 ..< 384 { bytes[i] = UInt8(i % 256) }
        let original = Data(bytes)
        let bigint = BigInt(original)
        let result = bigint.data
        #expect(result == original)
    }
}
