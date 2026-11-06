// AccessoryInfo.swift
// Copyright 2026 Monagle Pty Ltd

public struct AccessoryInfo: Sendable {
    public let name: String
    public let manufacturer: String
    public let model: String
    public let serialNumber: String
    public let firmwareRevision: String

    public init(
        name: String,
        manufacturer: String,
        model: String,
        serialNumber: String,
        firmwareRevision: String
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
    }
}
