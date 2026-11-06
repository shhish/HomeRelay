// HAPServiceTests.swift
// Copyright 2026 Monagle Pty Ltd

import Testing
@testable import HAPCore

@Suite("HAPService Tests")
struct HAPServiceTests {

    @Test("accessoryInformation factory creates 6 characteristics")
    func accessoryInformationFactory() {
        let service = HAPService.accessoryInformation(
            name: "Test",
            manufacturer: "Acumen",
            model: "Bridge",
            serialNumber: "001",
            firmwareRevision: "1.0.0",
            startIID: 1
        )
        #expect(service.type == .accessoryInformation)
        #expect(service.characteristics.count == 6)
        #expect(service.characteristics[0].type == .name)
        #expect(service.characteristics[5].type == .identify)
    }

    @Test("accessoryInformation IIDs are sequential from startIID+1")
    func accessoryInformationIIDs() {
        let service = HAPService.accessoryInformation(
            name: "Test", manufacturer: "M", model: "M",
            serialNumber: "S", firmwareRevision: "1.0",
            startIID: 10
        )
        // Service occupies startIID (10); characteristics start at startIID+1 (11)
        #expect(service.iid == 10)
        for (index, char) in service.characteristics.enumerated() {
            #expect(char.iid == UInt64(11 + index))
        }
    }

    @Test("securitySystem factory creates correct characteristics")
    func securitySystemFactory() {
        let service = HAPService.securitySystem(startIID: 7)
        #expect(service.type == .securitySystem)
        #expect(service.characteristics.count == 3)
        #expect(service.characteristics[0].type == .currentSecuritySystemState)
        #expect(service.characteristics[1].type == .targetSecuritySystemState)
        #expect(service.characteristics[2].type == .securitySystemAlarmType)
        #expect(service.characteristics[0].iid == 7)
        #expect(service.characteristics[1].iid == 8)
        #expect(service.characteristics[2].iid == 9)
    }

    @Test("securitySystem permissions")
    func securitySystemPermissions() {
        let service = HAPService.securitySystem(startIID: 1)
        // CurrentState: read + notify
        #expect(service.characteristics[0].isReadable)
        #expect(!service.characteristics[0].isWritable)
        #expect(service.characteristics[0].supportsNotification)
        // TargetState: read + write + notify
        #expect(service.characteristics[1].isReadable)
        #expect(service.characteristics[1].isWritable)
        #expect(service.characteristics[1].supportsNotification)
    }

    @Test("garageDoorOpener factory creates correct characteristics")
    func garageDoorOpenerFactory() {
        let service = HAPService.garageDoorOpener(startIID: 1)
        #expect(service.type == .garageDoorOpener)
        #expect(service.characteristics.count == 3)
        #expect(service.characteristics[0].type == .currentDoorState)
        #expect(service.characteristics[1].type == .targetDoorState)
        #expect(service.characteristics[2].type == .obstructionDetected)
    }

    @Test("identify characteristic is write-only")
    func identifyIsWriteOnly() {
        let char = HAPCharacteristic.identify(iid: 1)
        #expect(!char.isReadable)
        #expect(char.isWritable)
        #expect(!char.supportsNotification)
    }
}
