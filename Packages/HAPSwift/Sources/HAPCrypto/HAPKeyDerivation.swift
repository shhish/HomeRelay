// HAPKeyDerivation.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto

public enum HAPKeyDerivation {

    // MARK: - Constants

    public static let pairSetupEncryptSalt = Data("Pair-Setup-Encrypt-Salt".utf8)
    public static let pairSetupEncryptInfo = Data("Pair-Setup-Encrypt-Info".utf8)

    public static let pairVerifyEncryptSalt = Data("Pair-Verify-Encrypt-Salt".utf8)
    public static let pairVerifyEncryptInfo = Data("Pair-Verify-Encrypt-Info".utf8)

    public static let controlSalt = Data("Control-Salt".utf8)
    public static let controlWriteInfo = Data("Control-Write-Encryption-Key".utf8)
    public static let controlReadInfo = Data("Control-Read-Encryption-Key".utf8)

    // MARK: - Key Derivation

    public static func deriveKey(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int = 32
    ) -> SymmetricKey {
        let ikm = SymmetricKey(data: inputKeyMaterial)
        return HKDF<SHA512>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    public static func derivePairSetupEncryptionKey(from sessionKey: Data) -> SymmetricKey {
        deriveKey(
            inputKeyMaterial: sessionKey,
            salt: pairSetupEncryptSalt,
            info: pairSetupEncryptInfo
        )
    }

    public static func derivePairVerifyEncryptionKey(from sharedSecret: Data) -> SymmetricKey {
        deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: pairVerifyEncryptSalt,
            info: pairVerifyEncryptInfo
        )
    }

    // MARK: - Setup Hash

    /// Compute the HAP setup hash for the mDNS `sh` TXT record.
    ///
    /// Per HAP spec §5.3.3.4:
    /// ```
    /// sh = base64(SHA-512(setupID + deviceID)[0...3])
    /// ```
    /// This allows iOS to cryptographically bind a scanned QR code to the
    /// specific accessory advertising on the network. Without `sh`, iOS cannot
    /// verify the QR matches the discovered `_hap._tcp` service and will spin
    /// indefinitely on "Connecting...".
    public static func setupHash(setupID: String, deviceID: String) -> String {
        let input = Data((setupID + deviceID).utf8)
        let digest = SHA512.hash(data: input)
        let first4 = Data(digest.prefix(4))
        return first4.base64EncodedString()
    }

    public static func deriveSessionKeys(
        from sharedSecret: Data
    ) -> (writeKey: SymmetricKey, readKey: SymmetricKey) {
        let writeKey = deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: controlSalt,
            info: controlWriteInfo
        )
        let readKey = deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: controlSalt,
            info: controlReadInfo
        )
        return (writeKey: writeKey, readKey: readKey)
    }
}
