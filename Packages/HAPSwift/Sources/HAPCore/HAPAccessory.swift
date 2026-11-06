// HAPAccessory.swift
// Copyright 2026 Monagle Pty Ltd

public struct HAPAccessory: Sendable, Identifiable {
    public let aid: UInt64
    public var services: [HAPService]

    public var id: UInt64 { aid }

    public var name: String? {
        for service in services where service.type == .accessoryInformation {
            for characteristic in service.characteristics where characteristic.type == .name {
                if case .string(let name) = characteristic.value {
                    return name
                }
            }
        }
        return nil
    }

    public init(aid: UInt64, services: [HAPService]) {
        self.aid = aid
        self.services = services
    }
}
