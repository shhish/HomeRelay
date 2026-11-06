// HAPConnection.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import HAPCrypto
import Logging

/// Per-connection HTTP stream, pair-verify state and encryption counters.
/// All processing and socket sends share an explicit FIFO. Actor reentrancy alone
/// cannot preserve nonce order across awaits. Events enqueue without waiting, avoiding
/// a deadlock when two controllers write and notify each other at the same time.
public actor HAPConnection {
    private let session = HAPSession()
    private let protocolHandler: CharacteristicProtocol
    private let pairVerify: PairVerifyStateMachine
    private let send: @Sendable (Data) async throws -> Void
    private let close: @Sendable () -> Void
    private let logger: Logger
    private var wireBuffer = Data()
    private var httpBuffer = Data()
    private var tail: Task<Void, Never>?
    private var failed = false
    private var queuedEvents = 0

    public init(bridge: HAPBridge, setupCode: String, identity: HAPIdentity, pairingStore: any PairingStore,
                deviceID: String, connectionID: Int,
                onPairingChange: (@Sendable () async -> Void)? = nil,
                logger: Logger = Logger(label: "hap.connection"),
                send: @escaping @Sendable (Data) async throws -> Void,
                close: @escaping @Sendable () -> Void) {
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: pairingStore, deviceID: deviceID)
        self.pairVerify = verify
        self.protocolHandler = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: PairingStateMachine(setupCode: setupCode, identity: identity,
                                                     pairingStore: pairingStore, deviceID: deviceID),
            pairVerifyStateMachine: verify, pairingStore: pairingStore, identity: identity,
            connectionID: connectionID, onPairingChange: onPairingChange)
        self.send = send
        self.close = close
        self.logger = logger
    }

    public func receive(_ data: Data) async {
        let previous = tail
        let operation = Task {
            await previous?.value
            guard !failed else { return }
            do { try await process(data) }
            catch { fail(error) }
        }
        tail = operation
        await operation.value
    }

    public func sendEvent(_ data: Data) {
        guard !failed else { return }
        // A stalled subscriber must reconnect and read current state rather than
        // retaining an unbounded chain of event tasks in an always-on bridge.
        guard queuedEvents < 256 else { fail(HAPError.busy); return }
        queuedEvents += 1
        let previous = tail
        tail = Task {
            defer { queuedEvents -= 1 }
            await previous?.value
            guard !failed, await session.isEncrypted else { return }
            do {
                guard try await pairVerify.isAuthorized() else { throw HAPError.authenticationFailed }
                try await send(session.encrypt(data))
            } catch { fail(error) }
        }
    }

    /// Called after a pairing change. Plaintext pair-setup connections have no session to revoke.
    public func revokeIfUnauthorized() async {
        guard await session.isEncrypted else { return }
        do {
            if try await !pairVerify.isAuthorized() { fail(HAPError.authenticationFailed) }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        wireBuffer.removeAll()
        httpBuffer.removeAll()
        logger.debug("Closing HAP connection: \(error)")
        close()
    }

    private func process(_ data: Data) async throws {
        wireBuffer.append(data)
        guard wireBuffer.count <= HTTPProtocol.maximumRequestSize + 65536 else { throw HTTPParseError.invalidRequest }
        while !failed {
            let encrypted = await session.isEncrypted
            if encrypted {
                guard try await pairVerify.isAuthorized() else { throw HAPError.authenticationFailed }
                var buffer = wireBuffer
                guard let plaintext = try await session.decryptFrame(from: &buffer) else { return }
                wireBuffer = buffer
                httpBuffer.append(plaintext)
            } else {
                httpBuffer.append(wireBuffer)
                wireBuffer.removeAll()
            }
            guard httpBuffer.count <= HTTPProtocol.maximumRequestSize + 16384 else { throw HTTPParseError.invalidRequest }
            while let parsed = try HTTPProtocol.parseNextRequest(from: httpBuffer) {
                httpBuffer.removeFirst(parsed.consumed)
                let response: HTTPResponse
                do { response = try await protocolHandler.handleRequest(parsed.request) }
                catch {
                    logger.error("HAP request failed: \(error)")
                    response = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                }
                let bytes = HTTPProtocol.serializeResponse(response)
                if encrypted { try await send(session.encrypt(bytes)) }
                else {
                    try await send(bytes)
                    if let keys = await pairVerify.sessionKeys() {
                        await session.establishSession(readKey: keys.readKey, writeKey: keys.writeKey)
                        // Bytes after verify M3 belong to the encrypted stream, even if
                        // TCP coalesced them with the last plaintext request.
                        wireBuffer = httpBuffer + wireBuffer
                        httpBuffer.removeAll()
                        break
                    }
                }
            }
            let nowEncrypted = await session.isEncrypted
            if !encrypted && !nowEncrypted { return }
            if wireBuffer.isEmpty { return }
        }
    }
}
