// PairVerifyStateMachine.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import HAPCore
import HAPCrypto

// MARK: - PairVerifyStateMachine

public actor PairVerifyStateMachine {
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private var state: State = .idle
    public private(set) var controllerIdentifier: String?
    private var controllerPublicKey: Data?

    public func isAuthorized() async throws -> Bool {
        guard let controllerIdentifier, let controllerPublicKey, sessionKeys() != nil else { return false }
        return try await pairingStore.publicKey(for: controllerIdentifier) == controllerPublicKey
    }

    private enum State {
        case idle
        case awaitingM3(sharedSecret: Data, accessoryEphemeralPublicKey: Data, controllerEphemeralPublicKey: Data)
        case verified(readKey: SymmetricKey, writeKey: SymmetricKey)
    }

    public init(identity: HAPIdentity, pairingStore: any PairingStore, deviceID: String) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
    }

    public func handleRequest(_ data: Data) async throws -> Data {
        let items = try TLV8.decode(data)

        guard let stateItem = items.first(where: { $0.type == TLV8Type.state.rawValue }),
              let stateValue = stateItem.value.first else {
            throw HAPPairingError.invalidState
        }

        switch stateValue {
        case 1: return try handleVerifyM1(items)
        case 3: return try await handleVerifyM3(items)
        default: throw HAPPairingError.invalidState
        }
    }

    public func sessionKeys() -> (readKey: SymmetricKey, writeKey: SymmetricKey)? {
        if case .verified(let readKey, let writeKey) = state {
            return (readKey: readKey, writeKey: writeKey)
        }
        return nil
    }

    // MARK: - Verify M1 → M2

    private func handleVerifyM1(_ items: [TLV8.Item]) throws -> Data {
        guard let controllerEphemeralPublicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value else {
            throw HAPPairingError.invalidState
        }

        controllerIdentifier = nil
        controllerPublicKey = nil
        // Generate accessory ephemeral key pair
        let accessoryEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let accessoryEphemeralPublicKey = Data(accessoryEphemeralPrivateKey.publicKey.rawRepresentation)

        // Perform ECDH
        let controllerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerEphemeralPublicKey)
        let sharedSecret = try accessoryEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: controllerKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        // Derive encryption key
        let encKey = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: sharedSecretData)

        // Build accessory info for signing
        var accessoryInfo = Data()
        accessoryInfo.append(accessoryEphemeralPublicKey)
        accessoryInfo.append(Data(deviceID.utf8))
        accessoryInfo.append(controllerEphemeralPublicKey)

        // Sign
        let signature = try identity.sign(accessoryInfo)

        // Build sub-TLV
        let subTLV = TLV8.encode([
            (type: TLV8Type.identifier.rawValue, value: Data(deviceID.utf8)),
            (type: TLV8Type.signature.rawValue, value: signature),
        ])

        // Encrypt sub-TLV
        let nonce = HAPEncryption.buildNonce(from: "PV-Msg02")
        let encrypted = try HAPEncryption.encrypt(plaintext: subTLV, key: encKey, nonce: nonce)

        self.state = .awaitingM3(
            sharedSecret: sharedSecretData,
            accessoryEphemeralPublicKey: accessoryEphemeralPublicKey,
            controllerEphemeralPublicKey: controllerEphemeralPublicKey
        )

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x02])),
            (type: TLV8Type.publicKey.rawValue, value: accessoryEphemeralPublicKey),
            (type: TLV8Type.encryptedData.rawValue, value: encrypted),
        ])
    }

    // MARK: - Verify M3 → M4

    private func handleVerifyM3(_ items: [TLV8.Item]) async throws -> Data {
        guard case .awaitingM3(let sharedSecret, let accessoryEphemeralPublicKey, let controllerEphemeralPublicKey) = state else {
            return errorResponse(state: 4, error: .authentication)
        }

        guard let encryptedData = items.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value else {
            self.state = .idle
            return errorResponse(state: 4, error: .authentication)
        }

        // Decrypt
        let encKey = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: sharedSecret)
        let nonce = HAPEncryption.buildNonce(from: "PV-Msg03")

        let decrypted: Data
        do {
            decrypted = try HAPEncryption.decrypt(ciphertext: encryptedData, key: encKey, nonce: nonce)
        } catch {
            self.state = .idle
            return errorResponse(state: 4, error: .authentication)
        }

        // Parse sub-TLV
        let subItems = try TLV8.decode(decrypted)

        guard let controllerIdentifier = subItems.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let controllerSignature = subItems.first(where: { $0.type == TLV8Type.signature.rawValue })?.value else {
            self.state = .idle
            return errorResponse(state: 4, error: .authentication)
        }

        // Look up controller public key
        let identifierString = String(data: controllerIdentifier, encoding: .utf8) ?? ""
        guard let controllerPublicKey = try await pairingStore.publicKey(for: identifierString) else {
            self.state = .idle
            return errorResponse(state: 4, error: .authentication)
        }

        // Build controller info for verification.
        // HAP spec: iOSDeviceInfo = iOSDeviceEphemeralPublicKey || iOSDevicePairingID || AccessoryEphemeralPublicKey
        var controllerInfo = Data()
        controllerInfo.append(controllerEphemeralPublicKey)
        controllerInfo.append(controllerIdentifier)
        controllerInfo.append(accessoryEphemeralPublicKey)

        // Verify signature
        let valid = try HAPIdentity.verify(
            signature: controllerSignature,
            data: controllerInfo,
            publicKey: controllerPublicKey
        )

        guard valid else {
            self.state = .idle
            return errorResponse(state: 4, error: .authentication)
        }

        // Derive session keys.
        // deriveSessionKeys returns keys named from the CONTROLLER's perspective:
        //   .writeKey = "Control-Write-Encryption-Key" — controller encrypts, accessory decrypts
        //   .readKey  = "Control-Read-Encryption-Key"  — accessory encrypts, controller decrypts
        // For the ACCESSORY's HAPSession we therefore swap them:
        //   session.readKey  (incoming data to decrypt) = Control-Write = derived.writeKey
        //   session.writeKey (outgoing data to encrypt) = Control-Read  = derived.readKey
        let derived = HAPKeyDerivation.deriveSessionKeys(from: sharedSecret)

        self.controllerPublicKey = controllerPublicKey
        self.controllerIdentifier = identifierString
        self.state = .verified(readKey: derived.writeKey, writeKey: derived.readKey)

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x04])),
        ])
    }

    // MARK: - Helpers

    private func errorResponse(state: UInt8, error: TLV8ErrorCode) -> Data {
        TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([state])),
            (type: TLV8Type.error.rawValue, value: Data([error.rawValue])),
        ])
    }
}
