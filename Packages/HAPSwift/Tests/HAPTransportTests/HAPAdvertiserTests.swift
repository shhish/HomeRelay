// HAPAdvertiserTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import MDNSCore
import HAPCore
@testable import HAPTransport

// MARK: - Mock ServiceDiscovery

final class MockServiceDiscovery: ServiceDiscovery, @unchecked Sendable {
    private let lock = NSLock()
    private var _advertisedRecords: [ServiceRecord] = []
    private var _stopped = false

    var advertisedRecords: [ServiceRecord] {
        lock.withLock { _advertisedRecords }
    }

    var stopped: Bool {
        lock.withLock { _stopped }
    }

    func advertise(service: ServiceRecord) async throws {
        lock.withLock { _advertisedRecords.append(service) }
    }

    func browse(serviceType: ServiceType) -> AsyncStream<ServiceRecord> {
        AsyncStream { _ in }
    }

    func resolve(_ record: ServiceRecord) async throws -> NetworkAddress {
        NetworkAddress(host: "127.0.0.1", port: record.port)
    }

    func stopAdvertising() async {
        lock.withLock { _stopped = true }
    }
}

// MARK: - Tests

@Suite("HAPAdvertiser Tests")
struct HAPAdvertiserTests {

    @Test("advertise creates correct service record")
    func advertiseRecord() async throws {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        try await advertiser.advertise(
            name: "Test Bridge",
            port: 51826,
            category: .bridge,
            configNumber: 1,
            isPaired: false
        )

        let records = mock.advertisedRecords
        #expect(records.count == 1)

        let record = records[0]
        #expect(record.name == "Test Bridge")
        #expect(record.serviceType == .hapAccessory)
        #expect(record.port == 51826)
        // HAP must advertise on all interfaces so iOS can discover it on any NIC
        #expect(record.advertiseOnAllInterfaces == true)
    }

    @Test("TXT records contain all required keys")
    func txtRecords() async throws {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        try await advertiser.advertise(
            name: "TestBridge",
            port: 51826,
            category: .bridge
        )

        let records = mock.advertisedRecords
        let txt = records[0].txtRecords

        #expect(txt["c#"] == "1")
        #expect(txt["ff"] == "0")
        #expect(txt["id"] == "AA:BB:CC:DD:EE:FF")
        #expect(txt["md"] == "TestBridge")
        #expect(txt["pv"] == "1.1")
        #expect(txt["s#"] == "1")
        #expect(txt["ci"] == "2")  // bridge
        // sh (setup hash) must be present — iOS requires it to bind QR code to service
        #expect(txt["sh"] != nil)
        #expect(txt["sh"]?.isEmpty == false)
    }

    @Test("unpaired — sf=1")
    func unpaired() async throws {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        try await advertiser.advertise(name: "B", port: 51826, category: .bridge, isPaired: false)

        let records = mock.advertisedRecords
        #expect(records[0].txtRecords["sf"] == "1")
    }

    @Test("paired — sf=0")
    func paired() async throws {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        try await advertiser.advertise(name: "B", port: 51826, category: .bridge, isPaired: true)

        let records = mock.advertisedRecords
        #expect(records[0].txtRecords["sf"] == "0")
    }

    @Test("category identifier for security system")
    func categoryIdentifier() async throws {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        try await advertiser.advertise(name: "Panel", port: 51826, category: .securitySystem)

        let records = mock.advertisedRecords
        #expect(records[0].txtRecords["ci"] == "11")
    }

    @Test("stop advertising")
    func stopAdvertising() async {
        let mock = MockServiceDiscovery()
        let advertiser = HAPAdvertiser(discovery: mock, deviceID: "AA:BB:CC:DD:EE:FF")

        await advertiser.stopAdvertising()

        let stopped = mock.stopped
        #expect(stopped)
    }
}
