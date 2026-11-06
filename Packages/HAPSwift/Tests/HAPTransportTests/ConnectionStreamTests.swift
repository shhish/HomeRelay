// ConnectionStreamTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
import HAPCrypto
import HAPTransport

private actor WireCapture {
    var bytes: [Data] = []
    func append(_ data: Data) { bytes.append(data) }
    func take() -> Data { defer { bytes.removeAll() }; return bytes.reduce(Data(), +) }
}

struct ConnectionStreamTests {
    @Test func encryptedHTTPSpansReadsAndFramesAndPreservesPipelinedRequests() async throws {
        let identity = HAPIdentity()
        let controller = HAPControllerSimulator()
        let store = InMemoryPairingStore()
        try await store.store(controllerIdentifier: controller.pairingID, publicKey: controller.identity.publicKeyData)
        let bridge = HAPBridge(info: AccessoryInfo(name: "Bridge", manufacturer: "Virtual", model: "Test", serialNumber: "test", firmwareRevision: "1"))
        let capture = WireCapture()
        let connection = HAPConnection(bridge: bridge, setupCode: AccessoryIdentity.generateSetupCode(), identity: identity,
                                       pairingStore: store, deviceID: "00:00:00:00:00:01", connectionID: 1,
                                       send: { await capture.append($0) }, close: {})
        func http(_ path: String, body: Data = Data()) -> Data {
            Data("POST \(path) HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        }
        func body(_ response: Data) throws -> Data {
            let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
            return Data(response[separator.upperBound...])
        }
        let (m1, ephemeral) = controller.buildVerifyM1()
        let request = http("/pair-verify", body: m1)
        for byte in request { await connection.receive(Data([byte])) }
        let m2 = try body(await capture.take())
        let (m3, secret) = try controller.buildVerifyM3(fromM2: m2, ephemeralPrivateKey: ephemeral,
                                                       accessoryLTPK: identity.publicKeyData)
        await connection.receive(http("/pair-verify", body: m3))
        try controller.verifyM4(body(await capture.take()))
        let keys = HAPKeyDerivation.deriveSessionKeys(from: secret)
        let session = HAPSession()
        await session.establishSession(readKey: keys.readKey, writeKey: keys.writeKey)
        let padding = Data(repeating: 32, count: 3500)
        let largeRequest = Data("GET /accessories HTTP/1.1\r\nContent-Length: \(padding.count)\r\n\r\n".utf8) + padding
        let second = Data("GET /characteristics?id=1.2 HTTP/1.1\r\n\r\n".utf8)
        let encrypted = try await session.encrypt(largeRequest + second)
        // TCP fragments include partial length headers, tags, and HTTP bodies.
        for offset in stride(from: 0, to: encrypted.count, by: 7) {
            await connection.receive(Data(encrypted[offset..<min(offset + 7, encrypted.count)]))
        }
        var responses = await capture.take()
        var plaintext = Data()
        while !responses.isEmpty {
            let frame = try #require(try await session.decryptFrame(from: &responses))
            plaintext.append(frame)
        }
        let text = String(decoding: plaintext, as: UTF8.self)
        #expect(text.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        #expect(text.contains("accessories"))
        #expect(text.contains("Bridge"))
    }
}
