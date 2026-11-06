// PairingStoreTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCrypto

@Suite("PairingStore Tests")
struct PairingStoreTests {

    @Test("store and retrieve")
    func storeAndRetrieve() async throws {
        let store = InMemoryPairingStore()
        let key = Data(repeating: 0xAB, count: 32)
        try await store.store(controllerIdentifier: "controller-1", publicKey: key)
        let retrieved = try await store.publicKey(for: "controller-1")
        #expect(retrieved == key)
    }

    @Test("retrieve non-existent returns nil")
    func retrieveNonExistent() async throws {
        let store = InMemoryPairingStore()
        let result = try await store.publicKey(for: "missing")
        #expect(result == nil)
    }

    @Test("remove controller")
    func removeController() async throws {
        let store = InMemoryPairingStore()
        let key = Data(repeating: 0xCD, count: 32)
        try await store.store(controllerIdentifier: "ctrl", publicKey: key)
        try await store.remove(controllerIdentifier: "ctrl")
        let result = try await store.publicKey(for: "ctrl")
        #expect(result == nil)
    }

    @Test("list pairings")
    func listPairings() async throws {
        let store = InMemoryPairingStore()
        try await store.store(controllerIdentifier: "a", publicKey: Data([0x01]))
        try await store.store(controllerIdentifier: "b", publicKey: Data([0x02]))
        let list = try await store.listPairings()
        #expect(list.count == 2)
    }

    @Test("isPaired flag")
    func isPairedFlag() async throws {
        let store = InMemoryPairingStore()
        let notPaired = await store.isPaired
        #expect(!notPaired)

        try await store.store(controllerIdentifier: "ctrl", publicKey: Data([0x01]))
        let paired = await store.isPaired
        #expect(paired)

        try await store.remove(controllerIdentifier: "ctrl")
        let afterRemove = await store.isPaired
        #expect(!afterRemove)
    }
}
