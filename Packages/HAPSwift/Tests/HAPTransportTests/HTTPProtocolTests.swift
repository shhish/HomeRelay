// HTTPProtocolTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPTransport

@Suite("HTTPProtocol Tests")
struct HTTPProtocolTests {

    @Test("parse GET request")
    func parseGetRequest() {
        let raw = "GET /accessories HTTP/1.1\r\nHost: 192.0.2.1\r\n\r\n"
        let request = HTTPProtocol.parseRequest(from: Data(raw.utf8))
        #expect(request != nil)
        #expect(request?.method == "GET")
        #expect(request?.path == "/accessories")
    }

    @Test("parse POST request with body")
    func parsePostRequest() {
        let raw = "POST /pair-setup HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 3\r\n\r\nABC"
        let request = HTTPProtocol.parseRequest(from: Data(raw.utf8))
        #expect(request != nil)
        #expect(request?.method == "POST")
        #expect(request?.path == "/pair-setup")
        #expect(request?.body == Data("ABC".utf8))
    }

    @Test("parse PUT request")
    func parsePutRequest() {
        let raw = "PUT /characteristics HTTP/1.1\r\nContent-Type: application/hap+json\r\n\r\n{}"
        let request = HTTPProtocol.parseRequest(from: Data(raw.utf8))
        #expect(request?.method == "PUT")
        #expect(request?.path == "/characteristics")
    }

    @Test("parse request with query string")
    func parseRequestWithQuery() {
        let raw = "GET /characteristics?id=1.10,1.11 HTTP/1.1\r\n\r\n"
        let request = HTTPProtocol.parseRequest(from: Data(raw.utf8))
        #expect(request?.path == "/characteristics?id=1.10,1.11")
    }

    @Test("serialize response")
    func serializeResponse() {
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: [(name: "Content-Type", value: "application/hap+json")],
            body: Data("{}".utf8)
        )
        let data = HTTPProtocol.serializeResponse(response)
        let string = String(data: data, encoding: .utf8)!
        #expect(string.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(string.contains("Content-Type: application/hap+json"))
        #expect(string.contains("Content-Length: 2"))
        #expect(string.hasSuffix("{}"))
    }

    @Test("content type constants")
    func contentTypes() {
        #expect(HTTPProtocol.hapJSON == "application/hap+json")
        #expect(HTTPProtocol.pairingTLV8 == "application/pairing+tlv8")
    }

    // MARK: - Binary Body Tests (HAP pairing requires these)

    @Test("binary body with non-UTF8 bytes is preserved exactly")
    func binaryBodyPreserved() {
        // Simulate pair-setup M3: body contains random bytes including values > 0x7F
        // that are NOT valid UTF-8 sequences. This is the exact scenario that caused
        // iOS to time out — the old String-based parser returned nil for these requests.
        let binaryBody = Data([0xFF, 0xFE, 0xC0, 0x80, 0x00, 0x01, 0x02])
        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: \(binaryBody.count)\r\n\r\n".utf8)
        raw.append(binaryBody)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request != nil, "Parser must handle binary bodies — returning nil causes iOS to time out waiting for M4")
        #expect(request?.method == "POST")
        #expect(request?.path == "/pair-setup")
        #expect(request?.body == binaryBody, "Binary body bytes must be preserved exactly")
    }

    @Test("384-byte SRP public key body is parsed correctly (pair-setup M3)")
    func srpPublicKeyBody() {
        // 384 bytes of high-entropy data — an actual SRP public key will contain bytes
        // throughout the full 0x00–0xFF range, making it invalid UTF-8.
        var srpPublicKey = Data(count: 384)
        for i in 0 ..< 384 {
            srpPublicKey[i] = UInt8(i % 256)
        }
        // Bytes 0x80–0xFF are multi-byte UTF-8 lead bytes; 0xC0,0xC1,0xF5–0xFF are
        // always invalid in UTF-8. This payload would cause the old parser to return nil.

        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 384\r\n\r\n".utf8)
        raw.append(srpPublicKey)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request != nil, "384-byte SRP public key body must parse — this is pair-setup M3")
        #expect(request?.body == srpPublicKey)
        #expect(request?.body.count == 384)
    }

    @Test("pair-setup M1 TLV8 body is parsed correctly")
    func pairSetupM1Body() {
        // M1 body: state=1 + method=0 encoded as TLV8.
        // Bytes: 06 01 01 00 01 00
        // Contains 0x00 (null) which String-based parsers might mishandle.
        let m1Body = Data([0x06, 0x01, 0x01, 0x00, 0x01, 0x00])
        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 6\r\n\r\n".utf8)
        raw.append(m1Body)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request?.body == m1Body)
    }

    @Test("incomplete body returns nil — waits for more data")
    func incompleteBodyReturnsNil() {
        // Content-Length says 100 bytes but only 50 are present — should return nil
        let partialBody = Data(repeating: 0x42, count: 50)
        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8)
        raw.append(partialBody)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request == nil, "Incomplete body must return nil so the server waits for the rest")
    }

    @Test("content-length used to extract exact body bytes")
    func contentLengthBoundary() {
        // Content-Length = 3 but buffer has 10 bytes of body — only 3 should be consumed
        let body = Data([0xAA, 0xBB, 0xCC])
        let extra = Data([0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44])
        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8)
        raw.append(body)
        raw.append(extra)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request?.body == body)
        #expect(request?.body.count == 3)
    }

    @Test("null bytes in body are preserved")
    func nullBytesPreserved() {
        let bodyWithNulls = Data([0x00, 0x01, 0x00, 0xFF, 0x00])
        var raw = Data("POST /pair-setup HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8)
        raw.append(bodyWithNulls)

        let request = HTTPProtocol.parseRequest(from: raw)
        #expect(request?.body == bodyWithNulls)
    }

    @Test("ok response helper")
    func okResponse() {
        let response = HTTPProtocol.okResponse(body: Data("test".utf8), contentType: "text/plain")
        #expect(response.statusCode == 200)
        #expect(response.body == Data("test".utf8))
        #expect(response.headers.first?.value == "text/plain")
    }

    @Test("error response helper")
    func errorResponseHelper() {
        let response = HTTPProtocol.errorResponse(status: 404, message: "Not Found")
        #expect(response.statusCode == 404)
        #expect(response.body.isEmpty)
    }
}
