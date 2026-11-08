// BridgeReliabilityTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import Crypto
import HAPCore
import HAPCrypto
@testable import HAPTransport

private let testInfo = AccessoryInfo(name: "Bridge", manufacturer: "Virtual", model: "Bridge", serialNumber: "test", firmwareRevision: "1")

private actor EventRecorder {
    var events: [(Set<Int>, Data)] = []
    func record(_ subscribers: Set<Int>, _ data: Data) { events.append((subscribers, data)) }
}

struct BridgeReliabilityTests {
    @Test func layoutRestartsReordersAndWraps() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBridgeConfigurationStore(url: dir.appendingPathComponent("layout.json"))
        let first = try HAPBridge(info: testInfo, configurationStore: store)
        try await first.addAccessory(info: testInfo, services: [.switch(startIID: 1), .contactSensor(startIID: 1)], aid: 10)
        try await first.endBatchUpdate()
        let firstDB = await first.accessoryDatabase()
        #expect(await first.currentConfigurationNumber == 1)
        let restart = try HAPBridge(info: testInfo, configurationStore: store)
        try await restart.addAccessory(info: testInfo, services: [.contactSensor(startIID: 1), .switch(startIID: 1)], aid: 10)
        try await restart.endBatchUpdate()
        #expect(await restart.currentConfigurationNumber == 1)
        let originalIDs = ids(firstDB)
        #expect(ids(await restart.accessoryDatabase()) == originalIDs)
        try await restart.addAccessory(info: testInfo, services: [.motionSensor(startIID: 1)], aid: 11)
        #expect(await restart.currentConfigurationNumber == 2)
        let addedIDs = ids(await restart.accessoryDatabase())
        #expect(originalIDs.allSatisfy { addedIDs[$0.key] == $0.value })
        var saved = try #require(try store.load())
        saved.configurationNumber = 65535
        try store.save(saved)
        let wrap = try HAPBridge(info: testInfo, configurationStore: store)
        try await wrap.addAccessory(info: testInfo, services: [.contactSensor(startIID: 1), .switch(startIID: 1)], aid: 10)
        try await wrap.endBatchUpdate() // removed AID 11
        #expect(await wrap.currentConfigurationNumber == 1)
        // Adding a service preserves every existing key; updating only values leaves c# alone.
        try await wrap.addAccessory(info: testInfo, services: [.motionSensor(startIID: 1), .switch(startIID: 1), .contactSensor(startIID: 1)], aid: 10)
        let expandedIDs = ids(await wrap.accessoryDatabase())
        #expect(originalIDs.allSatisfy { expandedIDs[$0.key] == $0.value })
        let number = await wrap.currentConfigurationNumber
        await wrap.updateCharacteristic(aid: 10, iid: try #require(expandedIDs["10/49/25"]), value: .bool(true))
        #expect(await wrap.currentConfigurationNumber == number)
    }

    private func ids(_ database: [HAPAccessory]) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for accessory in database {
            for service in accessory.services {
                result["\(accessory.aid)/\(service.type.rawValue)"] = service.iid
                for char in service.characteristics {
                    result["\(accessory.aid)/\(service.type.rawValue)/\(char.type.rawValue)"] = char.iid
                }
            }
        }
        return result
    }

    @Test func failedLayoutCommitRollsBackAndDoesNotAdvertise() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("layout.json")
        let bridge = try HAPBridge(info: testInfo, configurationStore: FileBridgeConfigurationStore(url: url))
        let recorder = EventRecorder()
        await bridge.addAccessoryChangeHandler { _ in await recorder.record([], Data()) }
        try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)], aid: 2)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await bridge.endBatchUpdate() }
        #expect(await bridge.accessoryDatabase().count == 1)
        #expect(await bridge.currentConfigurationNumber == 1)
        #expect(await recorder.events.isEmpty)
    }

    @Test func cancelledBatchRestoresLayoutAndAllowsANewBatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBridgeConfigurationStore(url: dir.appendingPathComponent("layout.json"))
        let bridge = try HAPBridge(info: testInfo, configurationStore: store)
        try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)], aid: 2)
        try await bridge.endBatchUpdate()
        await bridge.beginBatchUpdate()
        try await bridge.removeAccessory(aid: 2)
        try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)], aid: 3)
        await bridge.cancelBatchUpdate()
        #expect(await bridge.accessoryDatabase().map(\.aid) == [1, 2])
        // Out of batch mode: the next batch commits and bumps c#.
        await bridge.beginBatchUpdate()
        try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)], aid: 3)
        try await bridge.endBatchUpdate()
        #expect(await bridge.accessoryDatabase().map(\.aid) == [1, 2, 3])
        #expect(await bridge.currentConfigurationNumber == 2)
        #expect(try store.load()?.layout.contains("a:3:") == true)
    }

    @Test func writesNotifyPeersAndAppChangesNotifyEveryone() async throws {
        let bridge = HAPBridge(info: testInfo)
        let aid = try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)])
        let char = try #require(await bridge.accessoryDatabase().last?.services.last?.characteristics.first)
        let recorder = EventRecorder()
        await bridge.setCharacteristicChangeHandler { await recorder.record($0, $1) }
        await bridge.subscribe(connectionID: 1, aid: aid, iid: char.iid)
        await bridge.subscribe(connectionID: 2, aid: aid, iid: char.iid)
        try await bridge.writeCharacteristic(aid: aid, iid: char.iid, value: .bool(true), sourceConnectionID: 1)
        await bridge.updateCharacteristic(aid: aid, iid: char.iid, value: .bool(false))
        await bridge.updateCharacteristic(aid: aid, iid: char.iid, value: .bool(false))
        let events = await recorder.events
        #expect(events.count == 2)
        #expect(events[0].0 == [2])
        #expect(events[1].0 == [1, 2])
        #expect(String(decoding: events[0].1, as: UTF8.self).hasPrefix("EVENT/1.0 200 OK"))
        await bridge.unsubscribeAll(connectionID: 2)
        try await bridge.writeCharacteristic(aid: aid, iid: char.iid, value: .bool(true), sourceConnectionID: 1)
        #expect(await recorder.events.count == 2)
    }

    @Test func failedWriteHandlerDoesNotPublishValueOrEvent() async throws {
        let bridge = HAPBridge(info: testInfo)
        let aid = try await bridge.addAccessory(info: testInfo, services: [.switch(startIID: 1)])
        let iid = try #require(await bridge.accessoryDatabase().last?.services.last?.characteristics.first?.iid)
        await bridge.registerWriteHandler(aid: aid, iid: iid) { _ in throw HAPError.unavailable }
        await #expect(throws: HAPError.self) { try await bridge.writeCharacteristic(aid: aid, iid: iid, value: .bool(true)) }
        #expect(await bridge.readCharacteristic(aid: aid, iid: iid) == .bool(false))
    }

    @Test func fragmentedAndPipelinedHTTP() throws {
        let request = Data("PUT /characteristics HTTP/1.1\r\nContent-Length: 4\r\n\r\ntrue".utf8)
        for count in 0..<request.count { #expect(try HTTPProtocol.parseNextRequest(from: request.prefix(count)) == nil) }
        let combined = request + Data("GET /accessories HTTP/1.1\r\n\r\n".utf8)
        let first = try #require(try HTTPProtocol.parseNextRequest(from: combined))
        #expect(first.request.body == Data("true".utf8))
        #expect(first.consumed == request.count)
        let second = try #require(try HTTPProtocol.parseNextRequest(from: Data(combined.dropFirst(first.consumed))))
        #expect(second.request.path == "/accessories")
        #expect(second.request.body.isEmpty)
    }

    @Test(arguments: ["-1", "100000000", "invalid", "1\r\nContent-Length: 1"])
    func invalidLengthsAreRejected(_ length: String) {
        #expect(throws: HTTPParseError.self) {
            try HTTPProtocol.parseNextRequest(from: Data("PUT /characteristics HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))
        }
    }

    @Test(arguments: [1024, 1025, 250_000])
    func largeEncryptedResponsesRoundTrip(_ size: Int) async throws {
        let session = HAPSession()
        let key = SymmetricKey(size: .bits256)
        await session.establishSession(readKey: key, writeKey: key)
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        var frames = try await session.encrypt(bytes)
        var decrypted = Data()
        while !frames.isEmpty {
            let length = Int(frames[frames.startIndex]) | Int(frames[frames.startIndex + 1]) << 8
            #expect(length <= 1024)
            decrypted.append(try #require(try await session.decryptFrame(from: &frames)))
        }
        #expect(decrypted == bytes)
    }

    @Test func oversizedEncryptedFrameRejected() async {
        let session = HAPSession()
        let key = SymmetricKey(size: .bits256)
        await session.establishSession(readKey: key, writeKey: key)
        var buffer = Data([1, 4])
        await #expect(throws: (any Error).self) { try await session.decryptFrame(from: &buffer) }
    }
}
