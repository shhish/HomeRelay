// HAPCharacteristicValueTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCore

@Suite("HAPCharacteristicValue Tests")
struct HAPCharacteristicValueTests {

    @Test("format mapping for each case")
    func formatMapping() {
        #expect(HAPCharacteristicValue.bool(true).format == .bool)
        #expect(HAPCharacteristicValue.uint8(0).format == .uint8)
        #expect(HAPCharacteristicValue.uint16(0).format == .uint16)
        #expect(HAPCharacteristicValue.uint32(0).format == .uint32)
        #expect(HAPCharacteristicValue.int32(0).format == .int)
        #expect(HAPCharacteristicValue.float(0.0).format == .float)
        #expect(HAPCharacteristicValue.string("").format == .string)
        #expect(HAPCharacteristicValue.data(Data()).format == .data)
        #expect(HAPCharacteristicValue.tlv8(Data()).format == .tlv8)
    }

    @Test("equality")
    func equality() {
        #expect(HAPCharacteristicValue.uint8(3) == HAPCharacteristicValue.uint8(3))
        #expect(HAPCharacteristicValue.uint8(3) != HAPCharacteristicValue.uint8(4))
        #expect(HAPCharacteristicValue.string("a") != HAPCharacteristicValue.uint8(0))
    }
}
