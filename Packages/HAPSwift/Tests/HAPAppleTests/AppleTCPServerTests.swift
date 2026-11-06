// AppleTCPServerTests.swift
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Network
import Testing
import HAPCore
import HAPCrypto
import HAPTransport
import HAPApple

struct AppleTCPServerTests {
    @Test(.timeLimit(.minutes(1)))
    func loopbackListenerReassemblesPlaintextAndRequiresAuthorization() async throws {
        let bridge = HAPBridge(info: AccessoryInfo(name: "Test Bridge", manufacturer: "Virtual", model: "Test",
                                                  serialNumber: "test", firmwareRevision: "1"))
        let saved = try AccessoryIdentity(setupCode: AccessoryIdentity.generateSetupCode())
        let server = AppleTCPServer(bridge: bridge, setupCode: saved.setupCode, identity: try saved.identity,
                                    pairingStore: InMemoryPairingStore(), deviceID: saved.deviceID, loopbackOnly: true)
        try await server.start(port: 0)
        let port = server.port
        #expect(port > 0)
        await #expect(throws: HAPError.self) { try await server.start(port: 0) }
        let client = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        client.start(queue: DispatchQueue(label: "hap.test.client"))
        do {
            try await send(Data("GET /access".utf8), client)
            try await send(Data("ories HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8), client)
            let response: Data = try await withCheckedThrowingContinuation { continuation in
                client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 470"))
        } catch {
            client.cancel(); await server.stop(); throw error
        }
        client.cancel()
        await server.stop()
        // Rebinding the same fixed port must work after a clean stop.
        try await server.start(port: port)
        #expect(server.port == port)
        await server.stop()
    }

    private func send(_ data: Data, _ client: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
#endif
