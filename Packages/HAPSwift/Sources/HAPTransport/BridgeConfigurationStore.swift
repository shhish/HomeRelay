// BridgeConfigurationStore.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import HAPCrypto

/// Persistent layout and tombstoned IID allocations. Values are deliberately excluded.
public struct BridgeConfiguration: Codable, Sendable {
    public var version = 1
    public var configurationNumber: Int
    public var layout: String
    public var instanceIDs: [String: UInt64]

    public init(configurationNumber: Int = 1, layout: String = "", instanceIDs: [String: UInt64] = [:]) {
        self.configurationNumber = configurationNumber
        self.layout = layout
        self.instanceIDs = instanceIDs
    }
}

/// Synchronous commits run inside the bridge actor, without reentrancy between save and publish.
/// One store/file belongs to one bridge process; apps may supply another storage implementation.
public protocol BridgeConfigurationStore: Sendable {
    func load() throws -> BridgeConfiguration?
    func save(_ configuration: BridgeConfiguration) throws
}

public struct FileBridgeConfigurationStore: BridgeConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> BridgeConfiguration? {
        guard let data = try AtomicFile.read(url) else { return nil }
        let saved = try JSONDecoder().decode(BridgeConfiguration.self, from: data)
        guard saved.version == 1, (1...65535).contains(saved.configurationNumber),
              saved.instanceIDs.values.allSatisfy({ $0 >= 8 && $0 < UInt64.max }) else { throw HAPError.invalidState }
        var allocated: [String: Set<UInt64>] = [:]
        for (key, iid) in saved.instanceIDs {
            guard let aidKey = key.split(separator: "/").first, let aid = UInt64(aidKey), aid > 1, aid < UInt64.max,
                  allocated[String(aidKey), default: []].insert(iid).inserted else { throw HAPError.invalidState }
        }
        return saved
    }
    public func save(_ configuration: BridgeConfiguration) throws {
        try AtomicFile.write(JSONEncoder().encode(configuration), to: url)
    }
}
