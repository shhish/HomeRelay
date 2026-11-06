// CryptoInt.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
internal import CCryptoBoringSSL
internal import CCryptoBoringSSLShims

// MARK: - CryptoInt

/// Unsigned arbitrary-precision integer backed by BoringSSL's `BIGNUM`.
/// Internal to HAPCrypto — used exclusively by SRP.
/// Thread-safety: the backing BIGNUM is only accessed synchronously within
/// SRP operations. Copy-on-write ensures value semantics across actor boundaries.
struct CryptoInt: @unchecked Sendable, Equatable {
    private var backing: BackingStorage

    init() {
        self.backing = BackingStorage()
    }

    /// Initialize from big-endian `Data`.
    init(_ data: Data) {
        self.backing = BackingStorage(data: data)
    }

    init(_ value: UInt64) {
        self.backing = BackingStorage(value: value)
    }

    /// Big-endian `Data` representation.
    var data: Data {
        backing.withUnsafeBignumPointer { bnPtr in
            let numBytes = Int(CCryptoBoringSSL_BN_num_bytes(bnPtr))
            guard numBytes > 0 else { return Data([0]) }
            var bytes = [UInt8](repeating: 0, count: numBytes)
            bytes.withUnsafeMutableBufferPointer { buf in
                _ = CCryptoBoringSSLShims_BN_bn2bin(bnPtr, buf.baseAddress)
            }
            return Data(bytes)
        }
    }

    /// Big-endian `Data` padded to exactly `length` bytes.
    func paddedData(to length: Int) -> Data {
        backing.withUnsafeBignumPointer { bnPtr in
            let numBytes = Int(CCryptoBoringSSL_BN_num_bytes(bnPtr))
            guard numBytes > 0 else {
                return Data(repeating: 0, count: length)
            }
            if numBytes >= length {
                var bytes = [UInt8](repeating: 0, count: numBytes)
                bytes.withUnsafeMutableBufferPointer { buf in
                    _ = CCryptoBoringSSLShims_BN_bn2bin(bnPtr, buf.baseAddress)
                }
                return Data(bytes)
            }
            var padded = Data(repeating: 0, count: length)
            let offset = length - numBytes
            padded.withUnsafeMutableBytes { buf in
                _ = CCryptoBoringSSLShims_BN_bn2bin(bnPtr, buf.baseAddress! + offset)
            }
            return padded
        }
    }

    var isZero: Bool {
        backing.withUnsafeBignumPointer { bnPtr in
            CCryptoBoringSSL_BN_is_zero(bnPtr) == 1
        }
    }
}

// MARK: - BackingStorage

extension CryptoInt {
    fileprivate final class BackingStorage {
        private var bn: BIGNUM

        init() {
            self.bn = BIGNUM()
            CCryptoBoringSSL_BN_init(&self.bn)
        }

        init(data: Data) {
            self.bn = BIGNUM()
            CCryptoBoringSSL_BN_init(&self.bn)
            data.withUnsafeBytes { bytes in
                _ = CCryptoBoringSSLShims_BN_bin2bn(
                    bytes.baseAddress, bytes.count, &self.bn
                )
            }
        }

        init(value: UInt64) {
            self.bn = BIGNUM()
            CCryptoBoringSSL_BN_init(&self.bn)
            let rc = CCryptoBoringSSL_BN_set_u64(&self.bn, value)
            precondition(rc == 1, "BN_set_u64 failed")
        }

        init(copying other: BackingStorage) {
            self.bn = BIGNUM()
            CCryptoBoringSSL_BN_init(&self.bn)
            other.withUnsafeBignumPointer { srcPtr in
                let rc = CCryptoBoringSSL_BN_copy(&self.bn, srcPtr)
                precondition(rc != nil, "BN_copy failed")
            }
        }

        deinit {
            CCryptoBoringSSL_BN_clear_free(&self.bn)
        }

        func withUnsafeBignumPointer<T>(
            _ body: (UnsafePointer<BIGNUM>) throws -> T
        ) rethrows -> T {
            try body(&self.bn)
        }

        func withUnsafeMutableBignumPointer<T>(
            _ body: (UnsafeMutablePointer<BIGNUM>) throws -> T
        ) rethrows -> T {
            try body(&self.bn)
        }
    }

    /// Ensure copy-on-write before mutation.
    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&backing) {
            backing = BackingStorage(copying: backing)
        }
    }
}

// MARK: - BN_CTX Helper

extension CryptoInt {
    private static func withBN_CTX<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        let ctx = CCryptoBoringSSL_BN_CTX_new()!
        defer { CCryptoBoringSSL_BN_CTX_free(ctx) }
        return try body(ctx)
    }
}

// MARK: - Comparable

extension CryptoInt: Comparable {
    static func < (lhs: CryptoInt, rhs: CryptoInt) -> Bool {
        lhs.backing.withUnsafeBignumPointer { lhsPtr in
            rhs.backing.withUnsafeBignumPointer { rhsPtr in
                CCryptoBoringSSL_BN_cmp(lhsPtr, rhsPtr) < 0
            }
        }
    }

    static func == (lhs: CryptoInt, rhs: CryptoInt) -> Bool {
        lhs.backing.withUnsafeBignumPointer { lhsPtr in
            rhs.backing.withUnsafeBignumPointer { rhsPtr in
                CCryptoBoringSSL_BN_cmp(lhsPtr, rhsPtr) == 0
            }
        }
    }
}

// MARK: - Addition

extension CryptoInt {
    static func + (lhs: CryptoInt, rhs: CryptoInt) -> CryptoInt {
        let result = CryptoInt()
        result.backing.withUnsafeMutableBignumPointer { rPtr in
            lhs.backing.withUnsafeBignumPointer { aPtr in
                rhs.backing.withUnsafeBignumPointer { bPtr in
                    let rc = CCryptoBoringSSL_BN_add(rPtr, aPtr, bPtr)
                    precondition(rc == 1, "BN_add failed")
                }
            }
        }
        return result
    }
}

// MARK: - Subtraction

extension CryptoInt {
    /// Returns lhs - rhs. Caller must ensure lhs >= rhs for unsigned semantics.
    static func - (lhs: CryptoInt, rhs: CryptoInt) -> CryptoInt {
        let result = CryptoInt()
        result.backing.withUnsafeMutableBignumPointer { rPtr in
            lhs.backing.withUnsafeBignumPointer { aPtr in
                rhs.backing.withUnsafeBignumPointer { bPtr in
                    let rc = CCryptoBoringSSL_BN_sub(rPtr, aPtr, bPtr)
                    precondition(rc == 1, "BN_sub failed")
                }
            }
        }
        return result
    }
}

// MARK: - Multiplication

extension CryptoInt {
    static func * (lhs: CryptoInt, rhs: CryptoInt) -> CryptoInt {
        let result = CryptoInt()
        withBN_CTX { ctx in
            result.backing.withUnsafeMutableBignumPointer { rPtr in
                lhs.backing.withUnsafeBignumPointer { aPtr in
                    rhs.backing.withUnsafeBignumPointer { bPtr in
                        let rc = CCryptoBoringSSL_BN_mul(rPtr, aPtr, bPtr, ctx)
                        precondition(rc == 1, "BN_mul failed")
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Modulo

extension CryptoInt {
    /// Non-negative modulo: result is always in [0, rhs).
    static func % (lhs: CryptoInt, rhs: CryptoInt) -> CryptoInt {
        let result = CryptoInt()
        withBN_CTX { ctx in
            result.backing.withUnsafeMutableBignumPointer { rPtr in
                lhs.backing.withUnsafeBignumPointer { aPtr in
                    rhs.backing.withUnsafeBignumPointer { mPtr in
                        let rc = CCryptoBoringSSL_BN_nnmod(rPtr, aPtr, mPtr, ctx)
                        precondition(rc == 1, "BN_nnmod failed")
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Modular Exponentiation

extension CryptoInt {
    /// Computes `(base ^ exponent) mod modulus`.
    static func modPow(base: CryptoInt, exponent: CryptoInt, modulus: CryptoInt) -> CryptoInt {
        let result = CryptoInt()
        withBN_CTX { ctx in
            result.backing.withUnsafeMutableBignumPointer { rPtr in
                base.backing.withUnsafeBignumPointer { bPtr in
                    exponent.backing.withUnsafeBignumPointer { ePtr in
                        modulus.backing.withUnsafeBignumPointer { mPtr in
                            let rc = CCryptoBoringSSL_BN_mod_exp(
                                rPtr, bPtr, ePtr, mPtr, ctx
                            )
                            precondition(rc == 1, "BN_mod_exp failed")
                        }
                    }
                }
            }
        }
        return result
    }
}
