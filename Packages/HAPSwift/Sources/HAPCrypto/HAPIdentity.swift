// HAPIdentity.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto

public struct HAPIdentity: Sendable {
    private typealias Signer = Curve25519.Signing.PrivateKey
    private let signer: Signer

    public init() {
        self.signer = Signer()
    }

    public init(privateKeyData: Data) throws {
        guard privateKeyData.count == 32 else {
            throw HAPCryptoError.invalidKeyData
        }
        self.signer = try Signer(rawRepresentation: privateKeyData)
    }

    public var publicKeyData: Data {
        Data(signer.publicKey.rawRepresentation)
    }

    public var privateKeyData: Data {
        Data(signer.rawRepresentation)
    }

    public func sign(_ data: Data) throws -> Data {
        Data(try signer.signature(for: data))
    }

    public static func verify(signature: Data, data: Data, publicKey: Data) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: data)
    }
}
