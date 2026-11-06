// DurableStorageTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCrypto

struct DurableStorageTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func identitySurvivesReloadAndRejectsCorruption() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("identity.json")
        let code = AccessoryIdentity.generateSetupCode()
        let first = try await FileAccessoryIdentityStore(url: url).loadOrCreate(setupCode: code)
        let second = try await FileAccessoryIdentityStore(url: url).loadOrCreate(setupCode: code)
        #expect(first.deviceID == second.deviceID)
        #expect(first.privateKey == second.privateKey)
        #expect(first.setupCode == second.setupCode)
        #expect(first.setupID == second.setupID)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        await #expect(throws: (any Error).self) {
            try await FileAccessoryIdentityStore(url: url).loadOrCreate(setupCode: AccessoryIdentity.generateSetupCode())
        }
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await FileAccessoryIdentityStore(url: url).loadOrCreate(setupCode: code) }
        #expect(try Data(contentsOf: url) == Data("broken".utf8))
    }

    @Test func pairingsReloadWithPermissionsAndLastAdminRemoval() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pairings.json")
        let store = try FilePairingStore(url: url)
        let adminKey = HAPIdentity().publicKeyData
        let regularKey = HAPIdentity().publicKeyData
        #expect(try await store.storeInitialPairing(controllerIdentifier: "admin", publicKey: adminKey))
        #expect(try await store.storeInitialPairing(controllerIdentifier: "other", publicKey: adminKey) == false)
        try await store.store(controllerIdentifier: "user", publicKey: regularKey, permission: .regular)
        let loaded = try FilePairingStore(url: url)
        #expect(await loaded.publicKey(for: "admin") == adminKey)
        #expect(await loaded.permission(for: "user") == .regular)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        try await loaded.remove(controllerIdentifier: "admin")
        let empty = try FilePairingStore(url: url)
        #expect(await empty.isPaired == false)
        #expect(await empty.listPairings().isEmpty)
    }

    @Test func concurrentInitialPairingHasOneWinner() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FilePairingStore(url: dir.appendingPathComponent("pairings.json"))
        async let a = store.storeInitialPairing(controllerIdentifier: "one", publicKey: HAPIdentity().publicKeyData)
        async let b = store.storeInitialPairing(controllerIdentifier: "two", publicKey: HAPIdentity().publicKeyData)
        let results = try await [a, b]
        #expect(results.filter { $0 }.count == 1)
        #expect(await store.listPairings().count == 1)
    }

    @Test func failedCommitDoesNotPublishPairing() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pairings.json")
        let store = try FilePairingStore(url: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await store.store(controllerIdentifier: "admin", publicKey: HAPIdentity().publicKeyData, permission: .admin)
        }
        #expect(await store.isPaired == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["pairings.json"])
    }

    @Test func missingIdentityCannotBeRegeneratedWhenCreationIsDisabled() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("identity.json")
        await #expect(throws: (any Error).self) {
            try await FileAccessoryIdentityStore(url: url, allowsCreation: false).loadOrCreate(setupCode: AccessoryIdentity.generateSetupCode())
        }
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func directoryLockPreventsConcurrentWriters() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let lock = try StorageDirectoryLock(directory: dir)
            defer { withExtendedLifetime(lock) {} }
            #expect(throws: POSIXError.self) { try StorageDirectoryLock(directory: dir) }
        }
        let released = try StorageDirectoryLock(directory: dir)
        withExtendedLifetime(released) {}
    }

    @Test func corruptPairingsAreNotReset() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pairings.json")
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try FilePairingStore(url: url) }
    }
}
