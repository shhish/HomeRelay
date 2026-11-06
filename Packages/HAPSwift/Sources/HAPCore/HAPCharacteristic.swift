// HAPCharacteristic.swift
// Copyright 2026 Monagle Pty Ltd

/// HAP characteristic unit types for numeric characteristics.
public enum HAPUnit: String, Sendable, Codable {
    case celsius
    case percentage
    case arcdegrees
    case lux
    case seconds
}

public struct HAPCharacteristic: Sendable, Identifiable {
    public let iid: UInt64
    public let type: HAPCharacteristicType
    public var value: HAPCharacteristicValue?
    public let permissions: [HAPPermission]
    public let format: HAPFormat

    // MARK: - Optional metadata (HAP spec §8)

    /// Minimum value for numeric characteristics.
    public var minValue: Double?
    /// Maximum value for numeric characteristics.
    public var maxValue: Double?
    /// Minimum step for numeric characteristics.
    public var minStep: Double?
    /// Unit for numeric characteristics.
    public var unit: HAPUnit?
    /// Valid values for enum-style characteristics (e.g., security system states).
    public var validValues: [Int]?

    public var id: UInt64 { iid }

    public var isReadable: Bool { permissions.contains(.read) }
    public var isWritable: Bool { permissions.contains(.write) }
    public var supportsNotification: Bool { permissions.contains(.notify) }

    public init(
        iid: UInt64,
        type: HAPCharacteristicType,
        value: HAPCharacteristicValue? = nil,
        permissions: [HAPPermission],
        format: HAPFormat,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        minStep: Double? = nil,
        unit: HAPUnit? = nil,
        validValues: [Int]? = nil
    ) {
        self.iid = iid
        self.type = type
        self.value = value
        self.permissions = permissions
        self.format = format
        self.minValue = minValue
        self.maxValue = maxValue
        self.minStep = minStep
        self.unit = unit
        self.validValues = validValues
    }
}

// MARK: - Factories

extension HAPCharacteristic {
    public static func name(_ value: String, iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .name, value: .string(value),
            permissions: [.read], format: .string
        )
    }

    public static func manufacturer(_ value: String, iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .manufacturer, value: .string(value),
            permissions: [.read], format: .string
        )
    }

    public static func model(_ value: String, iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .model, value: .string(value),
            permissions: [.read], format: .string
        )
    }

    public static func serialNumber(_ value: String, iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .serialNumber, value: .string(value),
            permissions: [.read], format: .string
        )
    }

    public static func firmwareRevision(_ value: String, iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .firmwareRevision, value: .string(value),
            permissions: [.read], format: .string
        )
    }

    public static func identify(iid: UInt64) -> HAPCharacteristic {
        HAPCharacteristic(
            iid: iid, type: .identify, value: nil,
            permissions: [.write], format: .bool
        )
    }
}
