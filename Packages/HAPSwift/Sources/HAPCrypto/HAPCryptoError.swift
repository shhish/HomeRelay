// HAPCryptoError.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPCryptoError: Error, Sendable {
    case invalidPublicKey
    case proofMismatch
    case encryptionFailed
    case decryptionFailed
    case invalidSignature
    case invalidKeyData
}
