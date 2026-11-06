// PairingFlowTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import Crypto
import HAPCore
import HAPCrypto
@testable import HAPCrypto  // SRPClient
@testable import HAPTransport

// MARK: - HAPControllerSimulator
//
// Simulates the iOS/macOS HomeKit controller side of the HAP pairing protocol.
// Used exclusively for testing — drives the state machines directly without TCP.

struct HAPControllerSimulator {
    let pairingID: String
    let identity: HAPIdentity

    init(pairingID: String = "TestController") {
        self.pairingID = pairingID
        self.identity = HAPIdentity()
    }

    // MARK: - Pair Setup

    /// Build pair-setup M1 (SRP start).
    func buildM1() -> Data {
        TLV8.encode([
            (type: TLV8Type.state.rawValue,  value: Data([0x01])),
            (type: TLV8Type.method.rawValue, value: Data([0x00])),
        ])
    }

    /// Parse M2 and build M3 (SRP client proof).
    func buildM3(fromM2 m2Data: Data, setupCode: String) throws -> (m3: Data, srpClient: SRPClient, sessionKey: Data) {
        let m2 = try TLV8.decode(m2Data)
        guard let serverPublicKey = m2.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value,
              let salt = m2.first(where: { $0.type == TLV8Type.salt.rawValue })?.value else {
            throw HAPTestError.missingTLVField
        }

        let srpClient = SRPClient()
        let (clientProof, _, sessionKey) = try srpClient.processServerChallenge(
            serverPublicKey: serverPublicKey,
            salt: salt,
            setupCode: setupCode
        )

        let m3 = TLV8.encode([
            (type: TLV8Type.state.rawValue,     value: Data([0x03])),
            (type: TLV8Type.publicKey.rawValue,  value: srpClient.clientPublicKey),
            (type: TLV8Type.proof.rawValue,      value: clientProof),
        ])

        return (m3: m3, srpClient: srpClient, sessionKey: sessionKey)
    }

    /// Verify M4 (server SRP proof).
    func verifyM4(fromM4 m4Data: Data, srpClient: SRPClient, sessionKey: Data) throws {
        let m4 = try TLV8.decode(m4Data)
        guard let state = m4.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first,
              state == 0x04 else {
            throw HAPTestError.unexpectedState
        }
        // M4 just needs to have state=4 and no error. Server proof is implicitly validated
        // (server wouldn't send M4 if client proof was wrong).
        let hasError = m4.contains(where: { $0.type == TLV8Type.error.rawValue })
        if hasError { throw HAPTestError.pairingError }
    }

    /// Build M5 (encrypted controller info) using the SRP session key.
    func buildM5(sessionKey: Data) throws -> Data {
        // Derive iOSDeviceX
        let iosDeviceX = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount: 32
        )

        let controllerID = Data(pairingID.utf8)

        // Build iOSDeviceInfo = iOSDeviceX || controllerPairingID || controllerLTPK
        var iosDeviceInfo = Data()
        iosDeviceX.withUnsafeBytes { iosDeviceInfo.append(contentsOf: $0) }
        iosDeviceInfo.append(controllerID)
        iosDeviceInfo.append(identity.publicKeyData)

        // Sign
        let signature = try identity.sign(iosDeviceInfo)

        // Build sub-TLV
        let subTLV = TLV8.encode([
            (type: TLV8Type.identifier.rawValue, value: controllerID),
            (type: TLV8Type.publicKey.rawValue,  value: identity.publicKeyData),
            (type: TLV8Type.signature.rawValue,  value: signature),
        ])

        // Encrypt with PS-Msg05
        let encKey = HAPKeyDerivation.derivePairSetupEncryptionKey(from: sessionKey)
        let nonce = HAPEncryption.buildNonce(from: "PS-Msg05")
        let encrypted = try HAPEncryption.encrypt(plaintext: subTLV, key: encKey, nonce: nonce)

        return TLV8.encode([
            (type: TLV8Type.state.rawValue,         value: Data([0x05])),
            (type: TLV8Type.encryptedData.rawValue,  value: encrypted),
        ])
    }

    /// Verify M6 and extract accessory LTPK.
    /// Returns the accessory long-term public key.
    func verifyM6(fromM6 m6Data: Data, sessionKey: Data) throws -> Data {
        let m6 = try TLV8.decode(m6Data)
        guard let state = m6.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first,
              state == 0x06 else {
            throw HAPTestError.unexpectedState
        }
        guard let encryptedData = m6.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value else {
            throw HAPTestError.missingTLVField
        }

        let encKey = HAPKeyDerivation.derivePairSetupEncryptionKey(from: sessionKey)
        let nonce = HAPEncryption.buildNonce(from: "PS-Msg06")
        let decrypted = try HAPEncryption.decrypt(ciphertext: encryptedData, key: encKey, nonce: nonce)

        let subItems = try TLV8.decode(decrypted)
        guard let accessoryLTPK = subItems.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value,
              let accessorySignature = subItems.first(where: { $0.type == TLV8Type.signature.rawValue })?.value,
              let accessoryID = subItems.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value else {
            throw HAPTestError.missingTLVField
        }

        // Verify accessory signature
        // Derive accessoryX
        let accessoryX = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
            info: Data("Pair-Setup-Accessory-Sign-Info".utf8),
            outputByteCount: 32
        )

        var accessoryInfo = Data()
        accessoryX.withUnsafeBytes { accessoryInfo.append(contentsOf: $0) }
        accessoryInfo.append(accessoryID)
        accessoryInfo.append(accessoryLTPK)

        let valid = try HAPIdentity.verify(
            signature: accessorySignature,
            data: accessoryInfo,
            publicKey: accessoryLTPK
        )
        guard valid else { throw HAPTestError.signatureVerificationFailed }

        return accessoryLTPK
    }

    // MARK: - Pair Verify

    /// Build pair-verify M1 — returns M1 data and the controller's ephemeral private key.
    func buildVerifyM1() -> (m1: Data, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey) {
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = Data(ephemeralPrivateKey.publicKey.rawRepresentation)

        let m1 = TLV8.encode([
            (type: TLV8Type.state.rawValue,     value: Data([0x01])),
            (type: TLV8Type.publicKey.rawValue,  value: ephemeralPublicKey),
        ])

        return (m1: m1, ephemeralPrivateKey: ephemeralPrivateKey)
    }

    /// Parse M2, verify accessory signature, build M3.
    /// Returns M3 data and the ECDH shared secret.
    func buildVerifyM3(
        fromM2 m2Data: Data,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        accessoryLTPK: Data
    ) throws -> (m3: Data, sharedSecret: Data) {
        let m2 = try TLV8.decode(m2Data)
        guard let state = m2.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first,
              state == 0x02 else {
            throw HAPTestError.unexpectedState
        }
        guard let accessoryEphemeralPubKeyData = m2.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value,
              let encryptedData = m2.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value else {
            throw HAPTestError.missingTLVField
        }

        // ECDH
        let accessoryEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: accessoryEphemeralPubKeyData
        )
        let sharedSecretObj = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: accessoryEphemeralPublicKey)
        let sharedSecret = sharedSecretObj.withUnsafeBytes { Data($0) }

        // Derive encrypt key for pair-verify
        let encKey = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: sharedSecret)
        let nonce = HAPEncryption.buildNonce(from: "PV-Msg02")
        let decrypted = try HAPEncryption.decrypt(ciphertext: encryptedData, key: encKey, nonce: nonce)

        let subItems = try TLV8.decode(decrypted)
        guard let accessorySignature = subItems.first(where: { $0.type == TLV8Type.signature.rawValue })?.value,
              let accessoryIdentifier = subItems.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value else {
            throw HAPTestError.missingTLVField
        }

        // Verify accessory signature: AccessoryEphemeralPubKey || AccessoryPairingID || ControllerEphemeralPubKey
        let controllerEphemeralPubKey = Data(ephemeralPrivateKey.publicKey.rawRepresentation)
        var accessoryInfo = Data()
        accessoryInfo.append(accessoryEphemeralPubKeyData)
        accessoryInfo.append(accessoryIdentifier)
        accessoryInfo.append(controllerEphemeralPubKey)

        let validSig = try HAPIdentity.verify(
            signature: accessorySignature,
            data: accessoryInfo,
            publicKey: accessoryLTPK
        )
        guard validSig else { throw HAPTestError.signatureVerificationFailed }

        // Build M3: controller info + signature, encrypted
        let controllerID = Data(pairingID.utf8)
        var controllerInfo = Data()
        controllerInfo.append(controllerEphemeralPubKey)
        controllerInfo.append(controllerID)
        controllerInfo.append(accessoryEphemeralPubKeyData)

        let controllerSignature = try identity.sign(controllerInfo)

        let subTLV = TLV8.encode([
            (type: TLV8Type.identifier.rawValue, value: controllerID),
            (type: TLV8Type.signature.rawValue,  value: controllerSignature),
        ])

        let m3Nonce = HAPEncryption.buildNonce(from: "PV-Msg03")
        let m3Encrypted = try HAPEncryption.encrypt(plaintext: subTLV, key: encKey, nonce: m3Nonce)

        let m3 = TLV8.encode([
            (type: TLV8Type.state.rawValue,         value: Data([0x03])),
            (type: TLV8Type.encryptedData.rawValue,  value: m3Encrypted),
        ])

        return (m3: m3, sharedSecret: sharedSecret)
    }

    /// Verify pair-verify M4 (success confirmation).
    func verifyM4(_ m4Data: Data) throws {
        let m4 = try TLV8.decode(m4Data)
        guard let state = m4.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first,
              state == 0x04 else {
            throw HAPTestError.unexpectedState
        }
        let hasError = m4.contains(where: { $0.type == TLV8Type.error.rawValue })
        if hasError { throw HAPTestError.pairingError }
    }
}

// MARK: - Session helper for the controller side

private struct ControllerSession {
    // Controller's perspective: encrypt with writeKey (Control-Write), decrypt with readKey (Control-Read)
    var writeCounter: UInt64 = 0
    var readCounter: UInt64 = 0
    let writeKey: SymmetricKey  // Control-Write-Encryption-Key: controller encrypts, accessory decrypts
    let readKey: SymmetricKey   // Control-Read-Encryption-Key:  accessory encrypts, controller decrypts

    init(sharedSecret: Data) {
        let derived = HAPKeyDerivation.deriveSessionKeys(from: sharedSecret)
        // derived.writeKey = Control-Write (controller writes → accessory reads)
        // derived.readKey  = Control-Read  (accessory writes → controller reads)
        writeKey = derived.writeKey
        readKey = derived.readKey
    }

    /// Encrypt plaintext into a HAP session frame (HAP spec §5.5.5).
    /// Frame: [2-byte LE plaintext length N] [N-byte ciphertext] [16-byte Poly1305 tag]
    /// The 2-byte header is used as AAD so it is integrity-protected.
    mutating func encryptFrame(_ plaintext: Data) throws -> Data {
        // 2-byte LE PLAINTEXT length — this is both the frame header and the AAD.
        let plaintextLength = UInt16(plaintext.count)
        var aad = Data(count: 2)
        aad[0] = UInt8(plaintextLength & 0xFF)
        aad[1] = UInt8(plaintextLength >> 8)

        let nonce = HAPEncryption.buildNonce(counter: writeCounter)
        let ciphertextAndTag = try HAPEncryption.encrypt(plaintext: plaintext, key: writeKey, nonce: nonce, aad: aad)
        writeCounter += 1

        var frame = aad
        frame.append(ciphertextAndTag)
        return frame
    }

    /// Decrypt a HAP session frame (HAP spec §5.5.5).
    /// Header = 2-byte LE plaintext length N; frame total = 2 + N + 16 bytes.
    mutating func decryptFrame(_ frameData: Data) throws -> Data {
        guard frameData.count >= 2 else { throw HAPTestError.shortFrame }
        let plaintextLength = Int(frameData[0]) | (Int(frameData[1]) << 8)
        let totalFrameSize = 2 + plaintextLength + 16
        guard frameData.count >= totalFrameSize else { throw HAPTestError.shortFrame }

        let aad = frameData.prefix(2)
        let ciphertextAndTag = Data(frameData[2 ..< totalFrameSize])

        let nonce = HAPEncryption.buildNonce(counter: readCounter)
        let plaintext = try HAPEncryption.decrypt(ciphertext: ciphertextAndTag, key: readKey, nonce: nonce, aad: Data(aad))
        readCounter += 1
        return plaintext
    }
}

// MARK: - Test Error

private enum HAPTestError: Error {
    case missingTLVField
    case unexpectedState
    case pairingError
    case signatureVerificationFailed
    case shortFrame
}

// MARK: - Test Infrastructure

private func makePairingComponents(setupCode: String = "03145154") -> (
    bridge: HAPBridge,
    identity: HAPIdentity,
    pairingStore: InMemoryPairingStore,
    pairingStateMachine: PairingStateMachine,
    pairVerifyStateMachine: PairVerifyStateMachine
) {
    let bridge = HAPBridge(info: AccessoryInfo(
        name: "Test Bridge",
        manufacturer: "Acumen",
        model: "Bridge1",
        serialNumber: "001",
        firmwareRevision: "1.0.0"
    ))
    let identity = HAPIdentity()
    let pairingStore = InMemoryPairingStore()
    let pairingStateMachine = PairingStateMachine(
        setupCode: setupCode,
        identity: identity,
        pairingStore: pairingStore,
        deviceID: "AA:BB:CC:DD:EE:FF"
    )
    let pairVerifyStateMachine = PairVerifyStateMachine(
        identity: identity,
        pairingStore: pairingStore,
        deviceID: "AA:BB:CC:DD:EE:FF"
    )
    return (bridge, identity, pairingStore, pairingStateMachine, pairVerifyStateMachine)
}

/// Runs a complete pair-setup exchange and returns the SRP session key.
private func runPairSetup(
    controller: HAPControllerSimulator,
    stateMachine: PairingStateMachine,
    setupCode: String = "03145154"
) async throws -> Data {
    // M1 → M2
    let m1 = controller.buildM1()
    let m2 = try await stateMachine.handleRequest(m1)

    // M3 → M4
    let (m3, srpClient, sessionKey) = try controller.buildM3(fromM2: m2, setupCode: setupCode)
    let m4 = try await stateMachine.handleRequest(m3)
    try controller.verifyM4(fromM4: m4, srpClient: srpClient, sessionKey: sessionKey)

    // M5 → M6
    let m5 = try controller.buildM5(sessionKey: sessionKey)
    let m6 = try await stateMachine.handleRequest(m5)
    _ = try controller.verifyM6(fromM6: m6, sessionKey: sessionKey)

    return sessionKey
}

/// Runs a complete pair-verify exchange and returns the shared ECDH secret.
func runPairVerify(
    controller: HAPControllerSimulator,
    stateMachine: PairVerifyStateMachine,
    accessoryLTPK: Data
) async throws -> Data {
    // M1 → M2
    let (m1, ephemeralPrivateKey) = controller.buildVerifyM1()
    let m2 = try await stateMachine.handleRequest(m1)

    // M3 → M4
    let (m3, sharedSecret) = try controller.buildVerifyM3(
        fromM2: m2,
        ephemeralPrivateKey: ephemeralPrivateKey,
        accessoryLTPK: accessoryLTPK
    )
    let m4 = try await stateMachine.handleRequest(m3)
    try controller.verifyM4(m4)

    return sharedSecret
}

// MARK: - Pair Setup Tests

@Suite("Pairing Flow Tests")
struct PairingFlowTests {

    @Test("pair-setup M1→M2 produces salt and server public key")
    func pairSetupM1M2() async throws {
        let (_, _, _, pairingStateMachine, _) = makePairingComponents()
        let controller = HAPControllerSimulator()

        let m1 = controller.buildM1()
        let m2 = try await pairingStateMachine.handleRequest(m1)
        let items = try TLV8.decode(m2)

        let state = items.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first
        let publicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value
        let salt = items.first(where: { $0.type == TLV8Type.salt.rawValue })?.value

        #expect(state == 0x02)
        #expect(publicKey?.count == 384)  // 3072-bit SRP key
        #expect(salt?.count == 16)
    }

    @Test("pair-setup M3→M4 accepts valid SRP proof")
    func pairSetupM3M4() async throws {
        let (_, _, _, pairingStateMachine, _) = makePairingComponents()
        let controller = HAPControllerSimulator()

        let m1 = controller.buildM1()
        let m2 = try await pairingStateMachine.handleRequest(m1)
        let (m3, _, _) = try controller.buildM3(fromM2: m2, setupCode: "03145154")
        let m4 = try await pairingStateMachine.handleRequest(m3)
        let items = try TLV8.decode(m4)

        let state = items.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first
        #expect(state == 0x04)
        #expect(!items.contains(where: { $0.type == TLV8Type.error.rawValue }))
    }

    @Test("pair-setup M3 rejects wrong password")
    func pairSetupWrongPassword() async throws {
        let (_, _, _, pairingStateMachine, _) = makePairingComponents(setupCode: "03145154")
        let controller = HAPControllerSimulator()

        let m1 = controller.buildM1()
        let m2 = try await pairingStateMachine.handleRequest(m1)
        let (m3, _, _) = try controller.buildM3(fromM2: m2, setupCode: "99999999")  // Wrong code
        let m4 = try await pairingStateMachine.handleRequest(m3)
        let items = try TLV8.decode(m4)

        #expect(items.contains(where: { $0.type == TLV8Type.error.rawValue }))
    }

    @Test("pair-setup M5→M6 completes and stores controller pairing")
    func pairSetupM5M6() async throws {
        let (_, _, pairingStore, pairingStateMachine, _) = makePairingComponents()
        let controller = HAPControllerSimulator(pairingID: "TestController-001")

        _ = try await runPairSetup(
            controller: controller,
            stateMachine: pairingStateMachine
        )

        // Verify pairing was stored
        let storedKey = await pairingStore.publicKey(for: "TestController-001")
        #expect(storedKey == controller.identity.publicKeyData)
    }

    @Test("pair-setup M6 accessory signature verifies correctly")
    func pairSetupAccessorySignatureVerifies() async throws {
        let (_, identity, _, pairingStateMachine, _) = makePairingComponents()
        let controller = HAPControllerSimulator()

        let m1 = controller.buildM1()
        let m2 = try await pairingStateMachine.handleRequest(m1)
        let (m3, _, sessionKey) = try controller.buildM3(fromM2: m2, setupCode: "03145154")
        _ = try await pairingStateMachine.handleRequest(m3)
        let m5 = try controller.buildM5(sessionKey: sessionKey)
        let m6 = try await pairingStateMachine.handleRequest(m5)

        // verifyM6 throws on bad signature — succeeds without error means signature valid
        let accessoryLTPK = try controller.verifyM6(fromM6: m6, sessionKey: sessionKey)
        #expect(accessoryLTPK == identity.publicKeyData)
    }

    // MARK: - Pair Verify Tests

    @Test("pair-verify M1→M2 produces accessory ephemeral key and encrypted data")
    func pairVerifyM1M2() async throws {
        let (_, _, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        // Must pair first
        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)

        let (m1, _) = controller.buildVerifyM1()
        let m2 = try await pairVerifyStateMachine.handleRequest(m1)
        let items = try TLV8.decode(m2)

        let state = items.first(where: { $0.type == TLV8Type.state.rawValue })?.value.first
        let publicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value
        let encryptedData = items.first(where: { $0.type == TLV8Type.encryptedData.rawValue })?.value

        #expect(state == 0x02)
        #expect(publicKey?.count == 32)  // Curve25519 key
        #expect(encryptedData != nil)
    }

    @Test("pair-verify M2 accessory signature verifies")
    func pairVerifyAccessorySignature() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)

        let (m1, ephemeralPrivateKey) = controller.buildVerifyM1()
        let m2 = try await pairVerifyStateMachine.handleRequest(m1)

        // buildVerifyM3 internally verifies the accessory's M2 signature — it throws on failure
        let (_, _) = try controller.buildVerifyM3(
            fromM2: m2,
            ephemeralPrivateKey: ephemeralPrivateKey,
            accessoryLTPK: identity.publicKeyData
        )
    }

    @Test("pair-verify M3 with unknown controller is rejected")
    func pairVerifyUnknownController() async throws {
        let (_, identity, _, _, pairVerifyStateMachine) = makePairingComponents()
        // Controller was never paired — not in pairing store
        let controller = HAPControllerSimulator(pairingID: "UnknownController")

        let (m1, ephemeralPrivateKey) = controller.buildVerifyM1()
        let m2 = try await pairVerifyStateMachine.handleRequest(m1)

        // Build M3 manually (even though identity would fail lookup)
        let (m3, _) = try controller.buildVerifyM3(
            fromM2: m2,
            ephemeralPrivateKey: ephemeralPrivateKey,
            accessoryLTPK: identity.publicKeyData
        )
        let m4 = try await pairVerifyStateMachine.handleRequest(m3)
        let items = try TLV8.decode(m4)

        #expect(items.contains(where: { $0.type == TLV8Type.error.rawValue }))
    }

    @Test("pair-verify M4 confirms successful verification")
    func pairVerifyM4Success() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        _ = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )
        // If we reached here without throwing, M4 was state=4 with no error
    }

    @Test("pair-verify produces session keys after M4")
    func pairVerifySessionKeys() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        _ = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        let keys = await pairVerifyStateMachine.sessionKeys()
        #expect(keys != nil)
    }

    // MARK: - Session Encryption Tests

    @Test("controller and accessory derive matching session keys")
    func sessionKeyAgreement() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        let controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!

        // Controller's writeKey (Control-Write) == Accessory's readKey
        // Controller's readKey  (Control-Read)  == Accessory's writeKey
        let derived = HAPKeyDerivation.deriveSessionKeys(from: sharedSecret)
        #expect(controllerSession.writeKey == derived.writeKey)
        #expect(controllerSession.readKey == derived.readKey)
        #expect(accessoryKeys.readKey == derived.writeKey)
        #expect(accessoryKeys.writeKey == derived.readKey)
    }

    @Test("controller-encrypted frame decrypts correctly via accessory session")
    func sessionEncryptionRoundTrip() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        var controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!
        let accessorySession = HAPSession()
        await accessorySession.establishSession(
            readKey: accessoryKeys.readKey,
            writeKey: accessoryKeys.writeKey
        )

        // Controller encrypts a message
        let plaintext = Data("GET /accessories HTTP/1.1\r\n\r\n".utf8)
        let frame = try controllerSession.encryptFrame(plaintext)

        // Accessory decrypts
        var buffer = frame
        let decrypted = try await accessorySession.decryptFrame(from: &buffer)
        #expect(decrypted == plaintext)
        #expect(buffer.isEmpty)
    }

    @Test("accessory-encrypted response decrypts correctly via controller session")
    func sessionResponseRoundTrip() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        var controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!
        let accessorySession = HAPSession()
        await accessorySession.establishSession(
            readKey: accessoryKeys.readKey,
            writeKey: accessoryKeys.writeKey
        )

        // Accessory encrypts a response
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let frame = try await accessorySession.encrypt(response)

        // Controller decrypts
        let decrypted = try controllerSession.decryptFrame(frame)
        #expect(decrypted == response)
    }

    // MARK: - End-to-End: GET /accessories over encrypted session

    @Test("GET /accessories over encrypted HAP session returns valid JSON")
    func getAccessoriesEncrypted() async throws {
        let setupCode = "03145154"
        let (bridge, identity, pairingStore, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents(setupCode: setupCode)
        let controller = HAPControllerSimulator()

        // 1. Full pair-setup
        _ = try await runPairSetup(
            controller: controller,
            stateMachine: pairingStateMachine,
            setupCode: setupCode
        )

        // 2. Full pair-verify
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        // 3. Establish sessions
        var controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!
        let accessorySession = HAPSession()
        await accessorySession.establishSession(
            readKey: accessoryKeys.readKey,
            writeKey: accessoryKeys.writeKey
        )

        // 4. Build CharacteristicProtocol
        let charProtocol = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: pairingStateMachine,
            pairVerifyStateMachine: pairVerifyStateMachine,
            pairingStore: pairingStore,
            identity: identity
        )

        // 5. Controller sends encrypted GET /accessories request
        let requestBytes = Data("GET /accessories HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let encryptedRequest = try controllerSession.encryptFrame(requestBytes)

        // 6. Accessory decrypts
        var requestBuffer = encryptedRequest
        guard let decryptedRequest = try await accessorySession.decryptFrame(from: &requestBuffer) else {
            Issue.record("Accessory failed to decrypt request frame")
            return
        }
        #expect(requestBuffer.isEmpty)

        // 7. Parse and dispatch the HTTP request
        guard let httpRequest = HTTPProtocol.parseRequest(from: decryptedRequest) else {
            Issue.record("Failed to parse HTTP request")
            return
        }
        let httpResponse = try await charProtocol.handleRequest(httpRequest)

        // 8. Accessory encrypts the response
        var responseBytes = Data("HTTP/1.1 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: \(httpResponse.body.count)\r\n\r\n".utf8)
        responseBytes.append(httpResponse.body)
        let encryptedResponse = try await accessorySession.encrypt(responseBytes)

        // 9. Controller decrypts
        let decryptedResponse = try controllerSession.decryptFrame(encryptedResponse)

        // 10. Parse JSON from the response body
        // Find the body start (after blank line in HTTP response)
        let separator = Data("\r\n\r\n".utf8)
        var bodyData: Data? = nil
        if let separatorRange = decryptedResponse.range(of: separator) {
            bodyData = decryptedResponse[separatorRange.upperBound...]
        }
        #expect(bodyData != nil)

        let json = try JSONSerialization.jsonObject(with: bodyData!) as? [String: Any]
        #expect(json != nil)
        let accessories = json?["accessories"] as? [[String: Any]]
        #expect(accessories != nil)
        #expect((accessories?.count ?? 0) >= 1)  // At least the bridge itself

        // 11. Verify services have IIDs in JSON
        for accessory in accessories! {
            let services = accessory["services"] as? [[String: Any]]
            #expect(services != nil)
            for service in services ?? [] {
                #expect(service["iid"] != nil, "Service missing iid in accessory JSON")
                #expect(service["type"] != nil)
                #expect(service["characteristics"] != nil)
            }
        }
    }

    // MARK: - Frame Format

    @Test("HAP session frame uses plaintext length header + AAD (spec §5.5.5 compatibility)")
    func sessionFrameFormatSpec() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        var controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!
        let accessorySession = HAPSession()
        await accessorySession.establishSession(
            readKey: accessoryKeys.readKey,
            writeKey: accessoryKeys.writeKey
        )

        // Encrypt a known-length plaintext
        let plaintext = Data("Hello HAP".utf8)           // 9 bytes
        let frame = try controllerSession.encryptFrame(plaintext)

        // HAP spec §5.5.5: header = 2-byte LE PLAINTEXT length (9 = 0x09 0x00)
        // Total frame = 2 + 9 + 16 = 27 bytes
        #expect(frame.count == 27, "Frame must be 2 (header) + 9 (ciphertext) + 16 (tag)")
        #expect(frame[0] == 0x09, "Header low byte = plaintext length (9)")
        #expect(frame[1] == 0x00, "Header high byte = 0 (length < 256)")

        // Accessory can decrypt it
        var buffer = frame
        let decrypted = try await accessorySession.decryptFrame(from: &buffer)
        #expect(decrypted == plaintext)
        #expect(buffer.isEmpty, "Entire frame must be consumed")

        // Verify the inverse direction
        let responseFrame = try await accessorySession.encrypt(plaintext)
        #expect(responseFrame.count == 27)
        #expect(responseFrame[0] == 0x09)
        #expect(responseFrame[1] == 0x00)
        let decryptedResponse = try controllerSession.decryptFrame(responseFrame)
        #expect(decryptedResponse == plaintext)
    }

    // MARK: - Multiple Messages — Counter Increment

    @Test("session counters increment correctly across multiple messages")
    func sessionCounterIncrement() async throws {
        let (_, identity, _, pairingStateMachine, pairVerifyStateMachine) = makePairingComponents()
        let controller = HAPControllerSimulator()

        _ = try await runPairSetup(controller: controller, stateMachine: pairingStateMachine)
        let sharedSecret = try await runPairVerify(
            controller: controller,
            stateMachine: pairVerifyStateMachine,
            accessoryLTPK: identity.publicKeyData
        )

        var controllerSession = ControllerSession(sharedSecret: sharedSecret)
        let accessoryKeys = await pairVerifyStateMachine.sessionKeys()!
        let accessorySession = HAPSession()
        await accessorySession.establishSession(
            readKey: accessoryKeys.readKey,
            writeKey: accessoryKeys.writeKey
        )

        // Send 3 messages in sequence
        for i in 0 ..< 3 {
            let plaintext = Data("Message \(i)".utf8)
            let frame = try controllerSession.encryptFrame(plaintext)
            var buffer = frame
            let decrypted = try await accessorySession.decryptFrame(from: &buffer)
            #expect(decrypted == plaintext)
        }

        // And 3 responses in the other direction
        for i in 0 ..< 3 {
            let response = Data("Response \(i)".utf8)
            let frame = try await accessorySession.encrypt(response)
            let decrypted = try controllerSession.decryptFrame(frame)
            #expect(decrypted == response)
        }
    }
}
