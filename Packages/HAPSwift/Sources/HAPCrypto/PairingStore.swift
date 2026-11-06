// PairingStore.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

public enum PairingPermission: UInt8, Sendable, Codable {
    case regular = 0
    case admin = 1
}

public struct ControllerPairing: Sendable, Codable, Equatable {
    public let identifier: String
    public let publicKey: Data
    public let permission: PairingPermission

    public init(identifier: String, publicKey: Data, permission: PairingPermission) {
        self.identifier = identifier
        self.publicKey = publicKey
        self.permission = permission
    }
}

public protocol PairingStore: Sendable {
    func store(controllerIdentifier: String, publicKey: Data, permission: PairingPermission) async throws
    /// Atomically claims an unpaired accessory. Only one concurrent pair-setup may succeed.
    func storeInitialPairing(controllerIdentifier: String, publicKey: Data) async throws -> Bool
    func publicKey(for controllerIdentifier: String) async throws -> Data?
    func permission(for controllerIdentifier: String) async throws -> PairingPermission?
    /// Removing or demoting the last admin removes all pairings (HAP §5.10–5.11).
    func remove(controllerIdentifier: String) async throws
    func listPairings() async throws -> [ControllerPairing]
    var isPaired: Bool { get async }
}

extension PairingStore {
    public func store(controllerIdentifier: String, publicKey: Data) async throws {
        try await store(controllerIdentifier: controllerIdentifier, publicKey: publicKey, permission: .admin)
    }
}

public actor InMemoryPairingStore: PairingStore {
    private var pairings: [String: ControllerPairing] = [:]

    public init() {}

    public func store(controllerIdentifier: String, publicKey: Data, permission: PairingPermission) {
        pairings[controllerIdentifier] = ControllerPairing(identifier: controllerIdentifier, publicKey: publicKey,
                                                          permission: permission)
        if !pairings.values.contains(where: { $0.permission == .admin }) { pairings.removeAll() }
    }

    public func storeInitialPairing(controllerIdentifier: String, publicKey: Data) -> Bool {
        guard pairings.isEmpty else { return false }
        store(controllerIdentifier: controllerIdentifier, publicKey: publicKey, permission: .admin)
        return true
    }

    public func publicKey(for controllerIdentifier: String) -> Data? { pairings[controllerIdentifier]?.publicKey }
    public func permission(for controllerIdentifier: String) -> PairingPermission? { pairings[controllerIdentifier]?.permission }

    public func remove(controllerIdentifier: String) {
        pairings.removeValue(forKey: controllerIdentifier)
        if !pairings.values.contains(where: { $0.permission == .admin }) { pairings.removeAll() }
    }

    public func listPairings() -> [ControllerPairing] { pairings.values.sorted { $0.identifier < $1.identifier } }
    public var isPaired: Bool { !pairings.isEmpty }
}

/// One instance per file, owned by one accessory process. Commits hit disk before success is returned.
public actor FilePairingStore: PairingStore {
    private struct Contents: Codable {
        var version = 1
        var pairings: [ControllerPairing]
    }
    private let url: URL
    private var pairings: [String: ControllerPairing]

    public init(url: URL) throws {
        self.url = url
        if let data = try AtomicFile.read(url) {
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard contents.version == 1,
                  Set(contents.pairings.map(\.identifier)).count == contents.pairings.count,
                  contents.pairings.allSatisfy({ !$0.identifier.isEmpty && $0.publicKey.count == 32 }),
                  contents.pairings.isEmpty || contents.pairings.contains(where: { $0.permission == .admin }) else {
                throw HAPCryptoError.invalidKeyData
            }
            pairings = Dictionary(uniqueKeysWithValues: contents.pairings.map { ($0.identifier, $0) })
        } else { pairings = [:] }
    }

    private func commit(_ candidate: [String: ControllerPairing]) throws {
        var candidate = candidate
        if !candidate.values.contains(where: { $0.permission == .admin }) { candidate.removeAll() }
        let contents = Contents(pairings: candidate.values.sorted { $0.identifier < $1.identifier })
        try AtomicFile.write(JSONEncoder().encode(contents), to: url)
        pairings = candidate
    }

    public func store(controllerIdentifier: String, publicKey: Data, permission: PairingPermission) throws {
        guard !controllerIdentifier.isEmpty, publicKey.count == 32 else { throw HAPCryptoError.invalidKeyData }
        var candidate = pairings
        candidate[controllerIdentifier] = ControllerPairing(identifier: controllerIdentifier, publicKey: publicKey,
                                                           permission: permission)
        try commit(candidate)
    }

    public func storeInitialPairing(controllerIdentifier: String, publicKey: Data) throws -> Bool {
        guard pairings.isEmpty else { return false }
        try store(controllerIdentifier: controllerIdentifier, publicKey: publicKey, permission: .admin)
        return true
    }

    public func publicKey(for controllerIdentifier: String) -> Data? { pairings[controllerIdentifier]?.publicKey }
    public func permission(for controllerIdentifier: String) -> PairingPermission? { pairings[controllerIdentifier]?.permission }
    public func remove(controllerIdentifier: String) throws {
        var candidate = pairings
        candidate.removeValue(forKey: controllerIdentifier)
        try commit(candidate)
    }
    public func listPairings() -> [ControllerPairing] { pairings.values.sorted { $0.identifier < $1.identifier } }
    public var isPaired: Bool { !pairings.isEmpty }
}
