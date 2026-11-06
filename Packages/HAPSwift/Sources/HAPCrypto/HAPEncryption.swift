// HAPEncryption.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto

public enum HAPEncryption {

    // MARK: - Encrypt

    /// Encrypt `plaintext` with ChaCha20-Poly1305.
    ///
    /// - Parameters:
    ///   - aad: Optional additional authenticated data. HAP session frames pass the 2-byte
    ///     LE plaintext-length header here per HAP spec §5.5.5. Pairing sub-messages
    ///     (M5, M6, PV-M2, PV-M3) leave this empty.
    public static func encrypt(
        plaintext: Data,
        key: SymmetricKey,
        nonce nonceData: Data,
        aad: Data = Data()
    ) throws -> Data {
        guard nonceData.count == 12 else {
            throw HAPCryptoError.encryptionFailed
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed: ChaChaPoly.SealedBox
        if aad.isEmpty {
            sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        } else {
            sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        }
        return sealed.ciphertext + sealed.tag
    }

    // MARK: - Decrypt

    /// Decrypt a ChaCha20-Poly1305 ciphertext (with appended 16-byte auth tag).
    ///
    /// - Parameters:
    ///   - aad: Optional additional authenticated data. Must match the `aad` used during
    ///     encryption — HAP session frames pass the 2-byte LE plaintext-length header here.
    public static func decrypt(
        ciphertext: Data,
        key: SymmetricKey,
        nonce nonceData: Data,
        aad: Data = Data()
    ) throws -> Data {
        guard nonceData.count == 12 else {
            throw HAPCryptoError.decryptionFailed
        }
        guard ciphertext.count >= 16 else {
            throw HAPCryptoError.decryptionFailed
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let tagStart = ciphertext.count - 16
        let ct = ciphertext[ciphertext.startIndex ..< ciphertext.startIndex + tagStart]
        let tag = ciphertext[ciphertext.startIndex + tagStart ..< ciphertext.endIndex]
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        if aad.isEmpty {
            return try ChaChaPoly.open(sealedBox, using: key)
        } else {
            return try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
        }
    }

    // MARK: - Nonce Builders

    /// Build 12-byte nonce from frame counter: 4 zero bytes + 8-byte LE counter.
    public static func buildNonce(counter: UInt64) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        var le = counter.littleEndian
        nonce.append(Data(bytes: &le, count: 8))
        return nonce
    }

    /// Build 12-byte nonce from string (e.g. "PS-Msg05"): 4 zero bytes + string bytes padded/truncated to 8.
    public static func buildNonce(from string: String) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        var stringBytes = Data(string.utf8)
        if stringBytes.count < 8 {
            stringBytes.append(Data(repeating: 0, count: 8 - stringBytes.count))
        } else if stringBytes.count > 8 {
            stringBytes = stringBytes.prefix(8)
        }
        nonce.append(stringBytes)
        return nonce
    }
}
