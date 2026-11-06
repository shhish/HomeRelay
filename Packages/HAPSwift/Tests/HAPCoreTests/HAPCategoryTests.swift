// HAPCategoryTests.swift
// Copyright 2026 Monagle Pty Ltd

import Testing
@testable import HAPCore

@Suite("HAPCategory Tests")
struct HAPCategoryTests {

    @Test("raw values match HAP spec")
    func rawValues() {
        #expect(HAPCategory.other.rawValue == 1)
        #expect(HAPCategory.bridge.rawValue == 2)
        #expect(HAPCategory.garageDoorOpener.rawValue == 4)
        #expect(HAPCategory.securitySystem.rawValue == 11)
    }
}
