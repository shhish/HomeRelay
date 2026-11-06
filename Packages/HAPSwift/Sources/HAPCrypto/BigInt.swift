// BigInt.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

// MARK: - BigInt

/// Unsigned arbitrary-precision integer backed by little-endian `[UInt64]` limbs.
/// Internal to HAPCrypto — used exclusively by SRP.
struct BigInt: Sendable, Equatable {
    /// Little-endian limbs (limbs[0] is the least significant).
    private(set) var limbs: [UInt64]

    init() {
        self.limbs = [0]
    }

    init(limbs: [UInt64]) {
        self.limbs = limbs.isEmpty ? [0] : limbs
        self.stripLeadingZeros()
    }

    /// Initialize from big-endian `Data`.
    init(_ data: Data) {
        guard !data.isEmpty else {
            self.limbs = [0]
            return
        }
        let bytes = Array(data)
        let limbCount = (bytes.count + 7) / 8
        var result = [UInt64](repeating: 0, count: limbCount)

        for i in 0 ..< bytes.count {
            let byteIndex = bytes.count - 1 - i
            let limbIndex = i / 8
            let bitOffset = (i % 8) * 8
            result[limbIndex] |= UInt64(bytes[byteIndex]) << bitOffset
        }

        self.limbs = result
        self.stripLeadingZeros()
    }

    init(_ value: UInt64) {
        self.limbs = [value]
    }

    /// Big-endian `Data` representation.
    var data: Data {
        if isZero { return Data([0]) }
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((limb >> shift) & 0xFF))
            }
        }
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }

    /// Big-endian `Data` padded to exactly `length` bytes.
    func paddedData(to length: Int) -> Data {
        let raw = self.data
        if raw.count >= length { return raw }
        var padded = Data(repeating: 0, count: length - raw.count)
        padded.append(raw)
        return padded
    }

    var isZero: Bool {
        limbs.allSatisfy { $0 == 0 }
    }

    var bitCount: Int {
        guard !isZero else { return 0 }
        let topLimb = limbs.count - 1
        return topLimb * 64 + (64 - limbs[topLimb].leadingZeroBitCount)
    }

    func bit(at index: Int) -> Bool {
        let limbIndex = index / 64
        let bitIndex = index % 64
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> bitIndex) & 1 == 1
    }

    private mutating func stripLeadingZeros() {
        while limbs.count > 1 && limbs.last == 0 {
            limbs.removeLast()
        }
    }
}

// MARK: - Comparable

extension BigInt: Comparable {
    static func < (lhs: BigInt, rhs: BigInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
        }
        return false
    }
}

// MARK: - Addition

extension BigInt {
    static func + (lhs: BigInt, rhs: BigInt) -> BigInt {
        let maxCount = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt64](repeating: 0, count: maxCount + 1)
        var carry: UInt64 = 0

        for i in 0 ..< maxCount {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result[i] = sum2
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        result[maxCount] = carry

        return BigInt(limbs: result)
    }
}

// MARK: - Subtraction

extension BigInt {
    /// Returns lhs - rhs. Requires lhs >= rhs.
    static func - (lhs: BigInt, rhs: BigInt) -> BigInt {
        var result = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0

        for i in 0 ..< lhs.limbs.count {
            let a = lhs.limbs[i]
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result[i] = diff2
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }

        return BigInt(limbs: result)
    }
}

// MARK: - Multiplication

extension BigInt {
    static func * (lhs: BigInt, rhs: BigInt) -> BigInt {
        let totalLimbs = lhs.limbs.count + rhs.limbs.count
        var result = [UInt64](repeating: 0, count: totalLimbs)

        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0 ..< rhs.limbs.count {
                let (hi, lo) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (sum1, o1) = result[i + j].addingReportingOverflow(lo)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            result[i + rhs.limbs.count] = carry
        }

        return BigInt(limbs: result)
    }
}

// MARK: - Shift

extension BigInt {
    func shiftedLeft(by count: Int) -> BigInt {
        guard count > 0 else { return self }
        let wholeLimbs = count / 64
        let bits = count % 64

        var result: [UInt64]
        if wholeLimbs > 0 {
            result = [UInt64](repeating: 0, count: wholeLimbs) + limbs
        } else {
            result = limbs
        }

        if bits > 0 {
            result.append(0)
            var carry: UInt64 = 0
            for i in wholeLimbs ..< result.count {
                let newCarry = result[i] >> (64 - bits)
                result[i] = (result[i] << bits) | carry
                carry = newCarry
            }
        }
        return BigInt(limbs: result)
    }
}

// MARK: - Division and Modulo

extension BigInt {
    /// Returns (quotient, remainder) using word-level long division.
    static func divmod(_ lhs: BigInt, _ rhs: BigInt) -> (BigInt, BigInt) {
        if rhs.isZero { fatalError("Division by zero") }
        if lhs < rhs { return (BigInt(0), lhs) }
        if lhs == rhs { return (BigInt(1), BigInt(0)) }

        let n = rhs.limbs.count

        // Single-limb divisor: fast path
        if n == 1 {
            return divmodSingleLimb(lhs, rhs.limbs[0])
        }

        // Multi-limb: Knuth Algorithm D
        return knuthDivision(lhs, rhs)
    }

    private static func divmodSingleLimb(_ lhs: BigInt, _ divisor: UInt64) -> (BigInt, BigInt) {
        var q = [UInt64](repeating: 0, count: lhs.limbs.count)
        var remainder: UInt64 = 0

        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            let (quotient, rem) = divisor.dividingFullWidth((remainder, lhs.limbs[i]))
            q[i] = quotient
            remainder = rem
        }

        return (BigInt(limbs: q), BigInt(remainder))
    }

    private static func knuthDivision(_ lhs: BigInt, _ rhs: BigInt) -> (BigInt, BigInt) {
        let n = rhs.limbs.count
        let m = lhs.limbs.count - n

        // D1: Normalize — shift so top bit of divisor is set
        let shift = rhs.limbs[n - 1].leadingZeroBitCount
        let v = rhs.shiftedLeft(by: shift)
        let u = lhs.shiftedLeft(by: shift)

        var uLimbs = u.limbs
        while uLimbs.count <= m + n { uLimbs.append(0) }

        var q = [UInt64](repeating: 0, count: m + 1)

        // D2-D7: Main loop
        for j in stride(from: m, through: 0, by: -1) {
            // D3: Calculate q̂
            let (qhat, _) = estimateQuotient(
                u0: uLimbs[j + n],
                u1: uLimbs[j + n - 1],
                u2: n >= 2 ? uLimbs[j + n - 2] : 0,
                v1: v.limbs[n - 1],
                v2: n >= 2 ? v.limbs[n - 2] : 0
            )

            // D4: Multiply and subtract — u[j..j+n] -= qhat * v[0..n-1]
            var borrow: UInt64 = 0
            var carry: UInt64 = 0

            for i in 0 ..< n {
                // qhat * v[i] + carry
                let (mulHi, mulLo) = mulAdd64(qhat, v.limbs[i], carry)
                carry = mulHi

                // u[j+i] - mulLo - borrow
                let (d1, b1) = uLimbs[j + i].subtractingReportingOverflow(mulLo)
                let (d2, b2) = d1.subtractingReportingOverflow(borrow)
                uLimbs[j + i] = d2
                borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
            }
            // Handle the top limb
            let (d1, b1) = uLimbs[j + n].subtractingReportingOverflow(carry)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            uLimbs[j + n] = d2
            let underflow = b1 || b2

            q[j] = qhat

            // D6: Add back if we overshot
            if underflow {
                q[j] -= 1
                var addCarry: UInt64 = 0
                for i in 0 ..< n {
                    let (s1, o1) = uLimbs[j + i].addingReportingOverflow(v.limbs[i])
                    let (s2, o2) = s1.addingReportingOverflow(addCarry)
                    uLimbs[j + i] = s2
                    addCarry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
                uLimbs[j + n] = uLimbs[j + n] &+ addCarry
            }
        }

        // D8: Unnormalize remainder
        var remLimbs = Array(uLimbs[0 ..< n])
        if shift > 0 {
            var carry: UInt64 = 0
            for i in stride(from: remLimbs.count - 1, through: 0, by: -1) {
                let newCarry = remLimbs[i] << (64 - shift)
                remLimbs[i] = (remLimbs[i] >> shift) | carry
                carry = newCarry
            }
        }

        return (BigInt(limbs: q), BigInt(limbs: remLimbs))
    }

    /// Estimate quotient digit q̂ from top limbs. Returns (qhat, rhat).
    private static func estimateQuotient(
        u0: UInt64, u1: UInt64, u2: UInt64,
        v1: UInt64, v2: UInt64
    ) -> (UInt64, UInt64) {
        // q̂ = (u0:u1) / v1, capped at base-1
        var qhat: UInt64
        var rhat: UInt64

        if u0 == v1 {
            qhat = UInt64.max
            // rhat = u0 + u1, but may overflow
            let (rh, overflow) = u1.addingReportingOverflow(v1)
            rhat = rh
            if overflow { return (qhat, rhat) }  // rhat >= base, skip refinement
        } else {
            (qhat, rhat) = v1.dividingFullWidth((u0, u1))
        }

        // Refine: while qhat * v2 > (rhat:u2)
        while true {
            let (prodHi, prodLo) = qhat.multipliedFullWidth(by: v2)
            // Compare (prodHi:prodLo) > (rhat:u2)
            if prodHi > rhat || (prodHi == rhat && prodLo > u2) {
                qhat -= 1
                let (newRhat, overflow) = rhat.addingReportingOverflow(v1)
                rhat = newRhat
                if overflow { break }  // rhat >= base
            } else {
                break
            }
        }

        return (qhat, rhat)
    }

    /// Returns (hi, lo) of a * b + c without overflow.
    private static func mulAdd64(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> (UInt64, UInt64) {
        let (hi, lo) = a.multipliedFullWidth(by: b)
        let (sumLo, overflow) = lo.addingReportingOverflow(c)
        let sumHi = hi &+ (overflow ? 1 : 0)
        return (sumHi, sumLo)
    }

    static func % (lhs: BigInt, rhs: BigInt) -> BigInt {
        divmod(lhs, rhs).1
    }
}

// MARK: - Modular Exponentiation

extension BigInt {
    /// Computes `(base ^ exponent) mod modulus` using square-and-multiply.
    static func modPow(base: BigInt, exponent: BigInt, modulus: BigInt) -> BigInt {
        guard !modulus.isZero else { fatalError("Modulus cannot be zero") }
        if modulus == BigInt(1) { return BigInt(0) }

        var result = BigInt(1)
        var base = base % modulus
        let expBits = exponent.bitCount

        for i in 0 ..< expBits {
            if exponent.bit(at: i) {
                result = (result * base) % modulus
            }
            base = (base * base) % modulus
        }

        return result
    }
}

// MARK: - Modular Inverse

extension BigInt {
    /// Computes modular inverse using extended Euclidean algorithm.
    func modInverse(_ modulus: BigInt) -> BigInt {
        var old_r = self
        var r = modulus
        var old_s = SignedBigInt(value: BigInt(1), negative: false)
        var s = SignedBigInt(value: BigInt(0), negative: false)

        while !r.isZero {
            let (q, remainder) = BigInt.divmod(old_r, r)
            old_r = r
            r = remainder

            let qs = SignedBigInt.multiply(
                SignedBigInt(value: q, negative: false), s)
            let new_s = SignedBigInt.subtract(old_s, qs)
            old_s = s
            s = new_s
        }

        if old_s.negative {
            return modulus - (old_s.value % modulus)
        } else {
            return old_s.value % modulus
        }
    }
}

// MARK: - Signed BigInt Helper

private struct SignedBigInt: Sendable {
    var value: BigInt
    var negative: Bool

    static func subtract(_ a: SignedBigInt, _ b: SignedBigInt) -> SignedBigInt {
        if a.negative == b.negative {
            if a.value >= b.value {
                return SignedBigInt(value: a.value - b.value, negative: a.negative)
            } else {
                return SignedBigInt(value: b.value - a.value, negative: !a.negative)
            }
        } else {
            return SignedBigInt(value: a.value + b.value, negative: a.negative)
        }
    }

    static func multiply(_ a: SignedBigInt, _ b: SignedBigInt) -> SignedBigInt {
        SignedBigInt(value: a.value * b.value, negative: a.negative != b.negative)
    }
}
