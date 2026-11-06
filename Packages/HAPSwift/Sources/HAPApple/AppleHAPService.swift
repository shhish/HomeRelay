// AppleHAPService.swift
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Logging
import MDNSCore
import MDNSApple
import HAPCore
import HAPCrypto
import HAPTransport

/// High-level Apple HAP service. For durable bridges pass an existing, restored
/// bridge, identity and pairing store. The convenience defaults are volatile.
public actor AppleHAPService {
    private let bridge: HAPBridge
    private let server: AppleTCPServer
    private let advertiser: HAPAdvertiser
    private let pairingStore: any PairingStore
    private let setupID: String
    private let logger: Logger
    private var started = false
    private var starting = false
    private var stopRequested = false
    private var handlersInstalled = false

    public init(info: AccessoryInfo, setupCode: String, deviceID: String, setupID: String = "ACMN",
                identity: HAPIdentity? = nil, pairingStore: (any PairingStore)? = nil,
                loopbackOnly: Bool = false, discovery: (any ServiceDiscovery)? = nil,
                logger: Logger = Logger(label: "hap.apple")) {
        self.init(bridge: HAPBridge(info: info), setupCode: setupCode, deviceID: deviceID, setupID: setupID,
                  identity: identity, pairingStore: pairingStore, loopbackOnly: loopbackOnly, discovery: discovery, logger: logger)
    }

    public init(bridge: HAPBridge, setupCode: String, deviceID: String, setupID: String = "ACMN",
                identity: HAPIdentity? = nil, pairingStore: (any PairingStore)? = nil,
                loopbackOnly: Bool = false, discovery: (any ServiceDiscovery)? = nil,
                logger: Logger = Logger(label: "hap.apple")) {
        let identity = identity ?? HAPIdentity()
        let pairingStore = pairingStore ?? InMemoryPairingStore()
        self.bridge = bridge
        self.pairingStore = pairingStore
        self.setupID = setupID
        self.logger = logger
        self.advertiser = HAPAdvertiser(discovery: discovery ?? AppleServiceDiscovery(logger: logger), deviceID: deviceID)
        self.server = AppleTCPServer(bridge: bridge, setupCode: setupCode, identity: identity, pairingStore: pairingStore,
                                    deviceID: deviceID, loopbackOnly: loopbackOnly, logger: logger)
    }

    public nonisolated var port: UInt16 { server.port }

    public func start(port: UInt16 = 0) async throws {
        guard !started, !starting else { throw HAPError.invalidState }
        starting = true
        stopRequested = false
        defer { starting = false }
        // Complete durable startup provisioning before a controller can see the database.
        try await bridge.endBatchUpdate()
        if !handlersInstalled {
            handlersInstalled = true
            server.onPairingChange = { [weak self] in await self?.refreshAdvertisement() }
            await bridge.addAccessoryChangeHandler { [weak self] _ in await self?.refreshAdvertisement() }
            await bridge.setCharacteristicChangeHandler { [weak server] subscribers, event in
                for connectionID in subscribers { await server?.sendEvent(event, to: connectionID) }
            }
        }
        guard !stopRequested else { throw HAPError.unavailable }
        do {
            try await server.start(port: port)
            guard !stopRequested else { throw HAPError.unavailable }
            started = true
            try await reAdvertise()
        } catch {
            started = false
            await server.stop()
            throw error
        }
        logger.info("HAP service started on port \(server.port)")
    }

    private func refreshAdvertisement() async {
        guard started else { return }
        do { try await reAdvertise() }
        catch { logger.error("HAP advertisement update failed: \(error)") }
    }

    public func reAdvertise() async throws {
        guard started else { throw HAPError.invalidState }
        let database = await bridge.accessoryDatabase()
        let model: String? = if case .string(let model) = await bridge.characteristic(aid: 1, iid: 4)?.value { model } else { nil }
        try await advertiser.advertise(name: database.first?.name ?? "HAP Bridge", model: model, port: server.port,
                                       category: bridge.category, setupID: setupID,
                                       configNumber: bridge.currentConfigurationNumber, isPaired: pairingStore.isPaired)
    }

    public func stop() async {
        stopRequested = true
        started = false
        await advertiser.stopAdvertising()
        await server.stop()
    }

    @discardableResult
    public func addAccessory(info: AccessoryInfo, services: [HAPService], aid: UInt64? = nil) async throws -> UInt64 {
        try await bridge.addAccessory(info: info, services: services, aid: aid)
    }
    public func removeAccessory(aid: UInt64) async throws { try await bridge.removeAccessory(aid: aid) }
    public func beginBatchUpdate() async { await bridge.beginBatchUpdate() }
    public func endBatchUpdate() async throws { try await bridge.endBatchUpdate() }
}
#endif
