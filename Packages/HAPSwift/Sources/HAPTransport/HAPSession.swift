// HAPSession.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import HAPCrypto

// MARK: - HAPSession

public actor HAPSession {
    private var readKey: SymmetricKey?
    private var writeKey: SymmetricKey?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    public var isEncrypted: Bool { readKey != nil }

    public init() {}

    public func establishSession(readKey: SymmetricKey, writeKey: SymmetricKey) {
        self.readKey = readKey
        self.writeKey = writeKey
        self.readCounter = 0
        self.writeCounter = 0
    }

    // MARK: - Encrypt

    /// Encrypts plaintext into a HAP session frame.
    ///
    /// HAP spec §5.5.5 frame layout:
    /// ```
    /// [2-byte LE: plaintext length N] [N bytes: ChaCha20 ciphertext] [16 bytes: Poly1305 tag]
    /// ```
    /// The 2-byte length header is used as the AAD (additional authenticated data) for
    /// ChaCha20-Poly1305, so it is integrity-protected alongside the ciphertext.
    public func encrypt(_ plaintext: Data) throws -> Data {
        guard let writeKey else { throw HAPCryptoError.encryptionFailed }

        var output = Data()
        var offset = 0
        while offset < plaintext.count {
            let count = min(1024, plaintext.count - offset)
            let chunk = Data(plaintext[plaintext.startIndex + offset ..< plaintext.startIndex + offset + count])
            let aad = Data([UInt8(count & 0xff), UInt8(count >> 8)])
            let nonce = HAPEncryption.buildNonce(counter: writeCounter)
            let encrypted = try HAPEncryption.encrypt(plaintext: chunk, key: writeKey, nonce: nonce, aad: aad)
            output.append(aad)
            output.append(encrypted)
            guard writeCounter < UInt64.max else { throw HAPCryptoError.encryptionFailed }
            writeCounter += 1
            offset += count
        }
        return output
    }

    // MARK: - Decrypt

    /// Attempts to decrypt a complete HAP session frame from the buffer.
    ///
    /// Returns decrypted plaintext if a complete frame is available, `nil` if more data is needed.
    /// Throws `HAPCryptoError.decryptionFailed` if the frame is present but authentication fails.
    ///
    /// HAP spec §5.5.5: the 2-byte LE **plaintext** length is the frame header and is used as AAD.
    /// Total frame size = 2 (header) + N (ciphertext) + 16 (auth tag).
    public func decryptFrame(from buffer: inout Data) throws -> Data? {
        guard let readKey else { throw HAPCryptoError.decryptionFailed }
        guard buffer.count >= 2 else { return nil }

        // Header encodes PLAINTEXT length N; ciphertext occupies N bytes, auth tag 16 bytes.
        let plaintextLength = Int(buffer[buffer.startIndex]) | (Int(buffer[buffer.startIndex + 1]) << 8)
        guard plaintextLength <= 1024 else { throw HAPCryptoError.decryptionFailed }
        let totalFrameSize = 2 + plaintextLength + 16

        guard buffer.count >= totalFrameSize else { return nil }  // incomplete frame — wait

        let aad = Data(buffer[buffer.startIndex ..< buffer.startIndex + 2])
        let ciphertextAndTag = Data(buffer[buffer.startIndex + 2 ..< buffer.startIndex + totalFrameSize])

        let nonce = HAPEncryption.buildNonce(counter: readCounter)
        let plaintext = try HAPEncryption.decrypt(ciphertext: ciphertextAndTag, key: readKey, nonce: nonce, aad: aad)

        guard readCounter < UInt64.max else { throw HAPCryptoError.decryptionFailed }
        self.readCounter += 1
        buffer.removeFirst(totalFrameSize)

        return plaintext
    }
}
