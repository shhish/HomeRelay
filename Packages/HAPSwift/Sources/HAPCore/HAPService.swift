// HAPService.swift
// Copyright 2026 Monagle Pty Ltd

public struct HAPService: Sendable {
    /// The instance identifier (IID) of this service within its accessory.
    /// Set to 0 for factory-constructed services; `HAPBridge.addAccessory`
    /// assigns the real IID before storing.
    public var iid: UInt64
    /// Stable logical identity for repeated services of the same type. Never use an array index.
    public var stableIdentifier: String?
    public let type: HAPServiceType
    public var characteristics: [HAPCharacteristic]

    public init(iid: UInt64 = 0, type: HAPServiceType, characteristics: [HAPCharacteristic], stableIdentifier: String? = nil) {
        self.stableIdentifier = stableIdentifier
        self.iid = iid
        self.type = type
        self.characteristics = characteristics
    }
}

// MARK: - Factories

extension HAPService {
    public static func accessoryInformation(
        name: String,
        manufacturer: String,
        model: String,
        serialNumber: String,
        firmwareRevision: String,
        startIID: UInt64 = 1
    ) -> HAPService {
        // The service occupies startIID; characteristics start at startIID + 1.
        var iid = startIID + 1
        var chars: [HAPCharacteristic] = []

        chars.append(.name(name, iid: iid)); iid += 1
        chars.append(.manufacturer(manufacturer, iid: iid)); iid += 1
        chars.append(.model(model, iid: iid)); iid += 1
        chars.append(.serialNumber(serialNumber, iid: iid)); iid += 1
        chars.append(.firmwareRevision(firmwareRevision, iid: iid)); iid += 1
        chars.append(.identify(iid: iid))

        return HAPService(iid: startIID, type: .accessoryInformation, characteristics: chars)
    }

    public static func protocolInformation(startIID: UInt64 = 1) -> HAPService {
        HAPService(iid: startIID, type: .protocolInformation, characteristics: [
            HAPCharacteristic(
                iid: startIID + 1,
                type: .version,
                value: .string("1.1.0"),
                permissions: [.read],
                format: .string
            ),
        ])
    }

    public static func securitySystem(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentSecuritySystemState, value: .uint8(3),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 4
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .targetSecuritySystemState, value: .uint8(3),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 3
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .securitySystemAlarmType, value: .uint8(0),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 1
        ))

        return HAPService(type: .securitySystem, characteristics: chars)
    }

    public static func garageDoorOpener(startIID: UInt64) -> HAPService {
        var iid = startIID
        var chars: [HAPCharacteristic] = []

        chars.append(HAPCharacteristic(
            iid: iid, type: .currentDoorState, value: .uint8(1),
            permissions: [.read, .notify], format: .uint8,
            minValue: 0, maxValue: 4
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .targetDoorState, value: .uint8(1),
            permissions: [.read, .write, .notify], format: .uint8,
            minValue: 0, maxValue: 1
        )); iid += 1

        chars.append(HAPCharacteristic(
            iid: iid, type: .obstructionDetected, value: .bool(false),
            permissions: [.read, .notify], format: .bool
        ))

        return HAPService(type: .garageDoorOpener, characteristics: chars)
    }
}
