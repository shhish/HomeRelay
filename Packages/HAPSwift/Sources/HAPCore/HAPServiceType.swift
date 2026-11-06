// HAPServiceType.swift
// Copyright 2026 Monagle Pty Ltd

/// A HAP service type UUID in short form (e.g. `"43"` for Lightbulb).
///
/// **Important — no leading zeros.** See ``HAPCharacteristicType`` for details.
public struct HAPServiceType: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Known Service Types

extension HAPServiceType {
    public static let accessoryInformation = HAPServiceType(rawValue: "3E")
    public static let securitySystem = HAPServiceType(rawValue: "7E")
    public static let garageDoorOpener = HAPServiceType(rawValue: "41")
    public static let protocolInformation = HAPServiceType(rawValue: "A2")
}

// MARK: - Full UUID

extension HAPServiceType {
    public var fullUUID: String {
        let hex = rawValue.uppercased()
        let padded = String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        return "\(padded)-0000-1000-8000-0026BB765291"
    }
}
