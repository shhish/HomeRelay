// HAPAdvertiser.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import HAPCrypto
import MDNSCore

// MARK: - ServiceType Extension

extension ServiceType {
    public static let hapAccessory = ServiceType("_hap._tcp")
}

// MARK: - HAPAdvertiser

public struct HAPAdvertiser: Sendable {
    private let discovery: any ServiceDiscovery
    private let deviceID: String

    public init(discovery: any ServiceDiscovery, deviceID: String) {
        self.discovery = discovery
        self.deviceID = deviceID
    }

    public func advertise(
        name: String,
        model: String? = nil,
        port: UInt16,
        category: HAPCategory,
        setupID: String = "ACMN",
        configNumber: Int = 1,
        isPaired: Bool = false
    ) async throws {
        guard (1...65535).contains(configNumber), port != 0 else { throw HAPError.invalidValue }
        let sh = HAPKeyDerivation.setupHash(setupID: setupID, deviceID: deviceID)
        let record = ServiceRecord(
            name: name,
            serviceType: .hapAccessory,
            host: "",
            port: port,
            txtRecords: [
                "c#": String(configNumber),
                "ff": "0",
                "id": deviceID,
                "md": model ?? name,
                "pv": "1.1",
                "s#": "1",
                "sf": isPaired ? "0" : "1",
                "ci": String(category.rawValue),
                "sh": sh,
            ],
            advertiseOnAllInterfaces: true
        )
        try await discovery.advertise(service: record)
    }

    public func stopAdvertising() async {
        await discovery.stopAdvertising()
    }
}
