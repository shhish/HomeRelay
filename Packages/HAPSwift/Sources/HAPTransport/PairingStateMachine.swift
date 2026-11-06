// PairingStateMachine.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Logging
import HAPCore
import HAPCrypto

// MARK: - PairingStateMachine

public actor PairingStateMachine {
    private let setupCode: String
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private var state: State = .idle
    private let logger = Logger(label: "hap.pairing")

    private enum State {
        case idle
        case awaitingM3(server: SRPServer)
        case awaitingM5(sessionKey: Data)
        case paired
        case error

        var name: String {
            switch self {
            case .idle: return "idle"
            case .awaitingM3: return "awaitingM3"
            case .awaitingM5: return "awaitingM5"
            case .paired: return "paired"
            case .error: return "error"
            }
        }
    }

    public init(setupCode: String, identity: HAPIdentity, pairingStore: any PairingStore, deviceID: String) {
        // HAP SRP uses the setup code in its display format (XXX-XX-XXX) including
        // dashes as the SRP password. All reference implementations (hap-nodejs,
        // HAP-python, esp-homekit) pass the formatted string with dashes to SRP.
        self.setupCode = setupCode
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
    }

    public func handleRequest(_ data: Data) async throws -> Data {
        logger.debug("handleRequest: \(data.count)B, current state=\(state.name)")

        let items: [TLV8.Item]
        do {
            items = try TLV8.decode(data)
        } catch {
            logger.error("handleRequest: TLV8 decode failed — \(error)")
            throw error
        }

        guard let stateItem = items.first(where: { $0.type == TLV8Type.state.rawValue }),
              let stateValue = stateItem.value.first else {
            logger.error("handleRequest: no state TLV item in \(data.count)B payload")
            throw HAPPairingError.invalidState
        }

        logger.debug("handleRequest: iOS state=\(stateValue)")

        switch stateValue {
        case 1: return try await handleM1(items)
        case 3: return try handleM3(items)
        case 5: return try await handleM5(items)
        default:
            logger.error("handleRequest: unrecognised state value \(stateValue)")
            throw HAPPairingError.invalidState
        }
    }

    // MARK: - M1 → M2

    private func handleM1(_ items: [TLV8.Item]) async throws -> Data {
        guard !(await pairingStore.isPaired) else { return errorResponse(state: 2, error: .unavailable) }
        // HAP 5.6.1: after 100 failed attempts, refuse pair setup (until restart here).
        guard await PairSetupAttempts.shared.allowed else { return errorResponse(state: 2, error: .maxTries) }
        logger.debug("M1: received (state=\(state.name))")

        guard case .idle = state else {
            logger.warning("M1: wrong state — returning error (state=\(state.name))")
            return errorResponse(state: 2, error: .unknown)
        }

        // Verify method is pair-setup (0x00)
        if let methodItem = items.first(where: { $0.type == TLV8Type.method.rawValue }),
           let method = methodItem.value.first, method != 0x00 {
            logger.warning("M1: unexpected method \(method) (expected 0x00)")
            return errorResponse(state: 2, error: .unknown)
        }

        let server = SRPServer(setupCode: setupCode)
        self.state = .awaitingM3(server: server)

        logger.debug("M1: sending M2 (B=\(server.serverPublicKey.count)B, salt=\(server.salt.count)B)")

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x02])),
            (type: TLV8Type.publicKey.rawValue, value: server.serverPublicKey),
            (type: TLV8Type.salt.rawValue, value: server.salt),
        ])
    }

    // MARK: - M3 → M4

    private func handleM3(_ items: [TLV8.Item]) throws -> Data {
        logger.debug("M3: received (state=\(state.name))")

        guard case .awaitingM3(let server) = state else {
            logger.warning("M3: wrong state — returning error (state=\(state.name))")
            return errorResponse(state: 4, error: .unknown)
        }

        guard let clientPublicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value,
              let clientProof = items.first(where: { $0.type == TLV8Type.proof.rawValue })?.value else {
            logger.error("M3: missing publicKey or proof TLV items")
            self.state = .error
            return errorResponse(state: 4, error: .authentication)
        }

        logger.debug("M3: A=\(clientPublicKey.count)B, M1=\(clientProof.count)B")

        do {
            let (serverProof, sessionKey) = try server.processClientProof(
                clientPublicKey: clientPublicKey,
                clientProof: clientProof
            )

            self.state = .awaitingM5(sessionKey: sessionKey)
            logger.debug("M3: proof accepted — sending M4 (M2=\(serverProof.count)B)")

            return TLV8.encode([
                (type: TLV8Type.state.rawValue, value: Data([0x04])),
                (type: TLV8Type.proof.rawValue, value: serverProof),
            ])
        } catch {
            logger.error("M3: proof REJECTED — \(error)")
            self.state = .error
            Task { await PairSetupAttempts.shared.failed() }
            return errorResponse(state: 4, error: .authentication)
        }
    }

    // MARK: - M5 → M6

    private func handleM5(_ items: [TLV8.Item]) async throws -> Data {
        guard case .awaitingM5(let sessionKey) = state else {
            logger.warning("M5: unexpected state (not awaitingM5, got \(state.name))")
            return errorResponse(state: 6, error: .unknown)
        }

        logger.debug("M5: received")

        guard let encryptedData = items.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value else {
            logger.warning("M5: missing encryptedData TLV item")
            self.state = .error
            return errorResponse(state: 6, error: .authentication)
        }

        logger.debug("M5: encryptedData \(encryptedData.count) bytes")

        // Derive encryption key for M5
        let encKey = HAPKeyDerivation.derivePairSetupEncryptionKey(from: sessionKey)
        let nonce = HAPEncryption.buildNonce(from: "PS-Msg05")

        // Decrypt M5 payload
        let decrypted: Data
        do {
            decrypted = try HAPEncryption.decrypt(ciphertext: encryptedData, key: encKey, nonce: nonce)
            logger.debug("M5: decryption succeeded (\(decrypted.count) bytes plaintext)")
        } catch {
            logger.error("M5: decryption failed")
            self.state = .error
            return errorResponse(state: 6, error: .authentication)
        }

        // Parse sub-TLV from decrypted data
        let subItems = try TLV8.decode(decrypted)

        guard let controllerIdentifier = subItems.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let controllerPublicKey = subItems.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value,
              let controllerSignature = subItems.first(where: { $0.type == TLV8Type.signature.rawValue })?.value else {
            let types = subItems.map { $0.type }
            logger.error("M5: sub-TLV missing required items. Found types: \(types)")
            self.state = .error
            return errorResponse(state: 6, error: .authentication)
        }

        logger.debug("M5: sub-TLV — identifier \(controllerIdentifier.count)B, publicKey \(controllerPublicKey.count)B, signature \(controllerSignature.count)B")

        // Derive iOSDeviceX for signature verification
        let iosDeviceX = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount: 32
        )

        // Build iOSDeviceInfo: iOSDeviceX + iOS device pairing ID + iOS device LTPK
        var iosDeviceInfo = Data()
        iosDeviceX.withUnsafeBytes { iosDeviceInfo.append(contentsOf: $0) }
        iosDeviceInfo.append(controllerIdentifier)
        iosDeviceInfo.append(controllerPublicKey)

        logger.debug("M5: iOSDeviceInfo \(iosDeviceInfo.count)B, verifying signature…")

        // Verify controller signature
        let valid: Bool
        do {
            valid = try HAPIdentity.verify(
                signature: controllerSignature,
                data: iosDeviceInfo,
                publicKey: controllerPublicKey
            )
        } catch {
            logger.error("M5: signature verification threw — \(error)")
            self.state = .error
            return errorResponse(state: 6, error: .authentication)
        }

        guard valid else {
            logger.error("M5: controller signature INVALID")
            self.state = .error
            return errorResponse(state: 6, error: .authentication)
        }

        logger.debug("M5: controller signature verified OK")

        // Store controller pairing
        let identifierString = String(data: controllerIdentifier, encoding: .utf8) ?? controllerIdentifier.hexString
        guard try await pairingStore.storeInitialPairing(controllerIdentifier: identifierString, publicKey: controllerPublicKey) else {
            self.state = .error
            return errorResponse(state: 6, error: .unavailable)
        }

        // Build M6 response
        // Derive AccessoryX for signature
        let accessoryX = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
            info: Data("Pair-Setup-Accessory-Sign-Info".utf8),
            outputByteCount: 32
        )

        let accessoryIdentifier = Data(deviceID.utf8)

        // Build accessory info: AccessoryX + accessory pairing ID + accessory LTPK
        var accessoryInfo = Data()
        accessoryX.withUnsafeBytes { accessoryInfo.append(contentsOf: $0) }
        accessoryInfo.append(accessoryIdentifier)
        accessoryInfo.append(identity.publicKeyData)

        // Sign
        let accessorySignature: Data
        do {
            accessorySignature = try identity.sign(accessoryInfo)
        } catch {
            logger.error("M6: accessory sign FAILED — \(error)")
            throw error
        }

        logger.debug("M6: accessoryInfo \(accessoryInfo.count)B, signature \(accessorySignature.count)B, LTPK \(identity.publicKeyData.count)B")

        // Build sub-TLV
        let subTLV = TLV8.encode([
            (type: TLV8Type.identifier.rawValue, value: accessoryIdentifier),
            (type: TLV8Type.publicKey.rawValue, value: identity.publicKeyData),
            (type: TLV8Type.signature.rawValue, value: accessorySignature),
        ])

        // Encrypt with PS-Msg06 nonce
        let m6Nonce = HAPEncryption.buildNonce(from: "PS-Msg06")
        let encrypted = try HAPEncryption.encrypt(plaintext: subTLV, key: encKey, nonce: m6Nonce)

        self.state = .paired
        logger.info("Pair-setup complete — controller \(identifierString)")

        return TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([0x06])),
            (type: TLV8Type.encryptedData.rawValue, value: encrypted),
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


/// Counts failed pair-setup attempts across connections. An 8-digit setup
/// code can't be brute-forced in 100 tries.
actor PairSetupAttempts {
    static let shared = PairSetupAttempts()
    static let limit = 100
    private var failures = 0

    var allowed: Bool { failures < Self.limit }

    func failed() { failures += 1 }

    func reset() { failures = 0 }
}
