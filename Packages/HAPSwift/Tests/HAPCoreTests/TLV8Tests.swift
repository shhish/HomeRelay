// TLV8Tests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCore

@Suite("TLV8 Tests")
struct TLV8Tests {

    @Test("encode empty value")
    func encodeEmptyValue() {
        let result = TLV8.encode([(type: 0x06, value: Data())])
        #expect(result == Data([0x06, 0x00]))
    }

    @Test("encode single short value")
    func encodeSingleShortValue() {
        let result = TLV8.encode([(type: 0x06, value: Data([0x01]))])
        #expect(result == Data([0x06, 0x01, 0x01]))
    }

    @Test("encode exactly 255 bytes — no fragmentation")
    func encodeExactly255Bytes() {
        let value = Data(repeating: 0xAB, count: 255)
        let result = TLV8.encode([(type: 0x03, value: value)])
        #expect(result.count == 2 + 255)
        #expect(result[0] == 0x03)
        #expect(result[1] == 255)
    }

    @Test("encode 256 bytes — fragments into 255 + 1")
    func encodeFragmented256Bytes() {
        let value = Data(repeating: 0xCD, count: 256)
        let result = TLV8.encode([(type: 0x03, value: value)])
        // First chunk: type + 255 + 255 bytes
        // Second chunk: type + 1 + 1 byte
        #expect(result.count == 2 + 255 + 2 + 1)
        #expect(result[0] == 0x03)
        #expect(result[1] == 255)
        #expect(result[257] == 0x03)
        #expect(result[258] == 1)
    }

    @Test("encode 600 bytes — fragments into 255 + 255 + 90")
    func encodeFragmentedLargeValue() {
        let value = Data(repeating: 0xEF, count: 600)
        let result = TLV8.encode([(type: 0x02, value: value)])
        #expect(result.count == (2 + 255) + (2 + 255) + (2 + 90))
    }

    @Test("decode single item")
    func decodeSingleItem() throws {
        let data = Data([0x06, 0x01, 0x02])
        let items = try TLV8.decode(data)
        #expect(items.count == 1)
        #expect(items[0].type == 0x06)
        #expect(items[0].value == Data([0x02]))
    }

    @Test("decode fragmented value — merges consecutive same-type entries")
    func decodeFragmentedValue() throws {
        var data = Data()
        // First fragment: type=3, length=255, 255 bytes of 0xAA
        data.append(0x03)
        data.append(255)
        data.append(Data(repeating: 0xAA, count: 255))
        // Second fragment: type=3, length=10, 10 bytes of 0xBB
        data.append(0x03)
        data.append(10)
        data.append(Data(repeating: 0xBB, count: 10))

        let items = try TLV8.decode(data)
        #expect(items.count == 1)
        #expect(items[0].type == 0x03)
        #expect(items[0].value.count == 265)
        #expect(items[0].value[254] == 0xAA)
        #expect(items[0].value[255] == 0xBB)
    }

    @Test("decode separator splits same-type items")
    func decodeSeparator() throws {
        var data = Data()
        // First item: type=1, value=[0x41]
        data.append(contentsOf: [0x01, 0x01, 0x41])
        // Separator
        data.append(contentsOf: [0xFF, 0x00])
        // Second item: type=1, value=[0x42]
        data.append(contentsOf: [0x01, 0x01, 0x42])

        let items = try TLV8.decode(data)
        #expect(items.count == 2)
        #expect(items[0].type == 0x01)
        #expect(items[0].value == Data([0x41]))
        #expect(items[1].type == 0x01)
        #expect(items[1].value == Data([0x42]))
    }

    @Test("round-trip encode then decode")
    func roundTrip() throws {
        let original: [TLV8.Item] = [
            (type: 0x06, value: Data([0x01])),
            (type: 0x03, value: Data(repeating: 0xFF, count: 48)),
            (type: 0x02, value: Data(repeating: 0x00, count: 16)),
        ]
        let encoded = TLV8.encode(original)
        let decoded = try TLV8.decode(encoded)
        #expect(decoded.count == original.count)
        for (a, b) in zip(original, decoded) {
            #expect(a.type == b.type)
            #expect(a.value == b.value)
        }
    }

    @Test("round-trip with fragmentation")
    func roundTripWithFragmentation() throws {
        let largeValue = Data(repeating: 0x42, count: 384)
        let original: [TLV8.Item] = [
            (type: 0x03, value: largeValue),
        ]
        let encoded = TLV8.encode(original)
        let decoded = try TLV8.decode(encoded)
        #expect(decoded.count == 1)
        #expect(decoded[0].value == largeValue)
    }

    @Test("decode malformed — truncated mid-value")
    func decodeMalformedTruncated() {
        let data = Data([0x06, 0x05, 0x01, 0x02])  // claims 5 bytes but only 2
        #expect(throws: HAPError.self) {
            _ = try TLV8.decode(data)
        }
    }

    @Test("decode malformed — truncated header")
    func decodeMalformedTruncatedHeader() {
        let data = Data([0x06])  // only type byte, no length
        #expect(throws: HAPError.self) {
            _ = try TLV8.decode(data)
        }
    }

    @Test("decode empty data")
    func decodeEmpty() throws {
        let items = try TLV8.decode(Data())
        #expect(items.isEmpty)
    }

    @Test("multiple different types round-trip")
    func roundTripMixedTypes() throws {
        let original: [TLV8.Item] = [
            (type: TLV8Type.state.rawValue, value: Data([0x01])),
            (type: TLV8Type.method.rawValue, value: Data([0x00])),
        ]
        let encoded = TLV8.encode(original)
        let decoded = try TLV8.decode(encoded)
        #expect(decoded.count == 2)
        #expect(decoded[0].type == TLV8Type.state.rawValue)
        #expect(decoded[1].type == TLV8Type.method.rawValue)
    }
}
