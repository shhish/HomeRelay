// HAPBridge.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import Logging

// MARK: - HAPBridge

public actor HAPBridge {
    private let logger = Logger(label: "hap.bridge")
    private var accessories: [UInt64: HAPAccessory] = [:]
    private var nextAID: UInt64 = 2
    private var writeHandlers: [String: @Sendable (HAPCharacteristicValue) async throws -> Void] = [:]
    public let category: HAPCategory

    // MARK: - Configuration number (c#)

    /// HAP configuration number — incremented when the accessory database changes.
    /// Persisted across restarts so paired iOS devices know to re-read /accessories.
    private var configurationNumber: Int = 1

    /// The current configuration number for mDNS advertisement.
    public var currentConfigurationNumber: Int { configurationNumber }

    private var configurationStore: (any BridgeConfigurationStore)?
    private var persistedLayout: String?
    private var instanceIDs: [String: UInt64] = [:]
    private var batchSnapshot: (accessories: [UInt64: HAPAccessory], ids: [String: UInt64], nextAID: UInt64)?

    /// For volatile bridges only. Durable bridges restore through their configuration store.
    public func restoreConfigurationNumber(_ n: Int) {
        guard configurationStore == nil else { return }
        configurationNumber = (1...65535).contains(n) ? n : 1
    }

    /// Reserve an AID so auto-assignment skips it.
    ///
    /// Call before provisioning to prevent new accessories from being
    /// auto-assigned AIDs that belong to existing device map entries.
    public func reserveAID(_ aid: UInt64) {
        if aid >= nextAID, aid < UInt64.max { nextAID = aid + 1 }
    }

    // MARK: - Accessory change handlers

    /// Callbacks fired when the accessory database changes (add/remove).
    /// Parameter is the new configuration number.
    private var accessoryChangeHandlers: [@Sendable (Int) async -> Void] = []

    /// Register a handler called when accessories are added or removed.
    /// Multiple handlers can be registered (e.g., re-advertisement + persistence).
    public func addAccessoryChangeHandler(_ handler: @escaping @Sendable (Int) async -> Void) {
        accessoryChangeHandlers.append(handler)
    }

    // MARK: - Batch updates

    private var isBatching = false

    /// Begin a batch update — suppresses c# increment and change notifications
    /// until ``endBatchUpdate()`` is called.
    public func beginBatchUpdate() {
        guard !isBatching else { return }
        isBatching = true
        batchSnapshot = (accessories, instanceIDs, nextAID)
    }

    /// Durable bridges start in a provisioning batch. Call once before opening the listener.
    /// Recreating the same database on restart leaves c# unchanged. A failed save rolls back.
    public func endBatchUpdate() async throws {
        guard isBatching else { return }
        do {
            let changed = try commitLayout()
            isBatching = false
                batchSnapshot = nil
            if changed { await notifyAccessoryChange() }
        } catch {
            if let snapshot = batchSnapshot {
                accessories = snapshot.accessories
                instanceIDs = snapshot.ids
                nextAID = snapshot.nextAID
            }
            throw error
        }
    }

    private func commitLayout() throws -> Bool {
        let layout = layoutDescription()
        guard layout != persistedLayout else { return false }
        let number = persistedLayout == nil ? configurationNumber : configurationNumber % 65535 + 1
        try configurationStore?.save(BridgeConfiguration(configurationNumber: number, layout: layout, instanceIDs: instanceIDs))
        configurationNumber = number
        persistedLayout = layout
        return true
    }

    private func incrementAndNotify() async throws {
        guard !isBatching else { return }
        if try commitLayout() { await notifyAccessoryChange() }
    }

    private func layoutDescription() -> String { Self.layoutDescription(accessoryDatabase()) }

    private static func layoutDescription(_ database: [HAPAccessory]) -> String {
        database.map { accessory in
            "a:\(accessory.aid):" + accessory.services.sorted { $0.iid < $1.iid }.map { service in
                "s:\(service.iid):\(service.type.rawValue):" + service.characteristics.sorted { $0.iid < $1.iid }.map { char in
                    "c:\(char.iid):\(char.type.rawValue):\(char.format.rawValue):\(char.permissions.map(\.rawValue).sorted().joined(separator: ","))"
                }.joined(separator: ";")
            }.joined(separator: "|")
        }.joined(separator: "\n")
    }

    private func notifyAccessoryChange() async {
        let cn = configurationNumber
        for handler in accessoryChangeHandlers {
            await handler(cn)
        }
    }

    // MARK: - Event subscriptions

    /// Maps "aid.iid" → set of connection IDs that subscribed to events.
    private var subscriptions: [String: Set<Int>] = [:]

    /// Called when a characteristic value changes and subscribers exist.
    /// Parameters: set of connection IDs, serialised EVENT/1.0 payload (pre-JSON,
    /// needs encryption per-connection).
    private var onCharacteristicChange: (@Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void)?

    /// Set the handler called when a subscribed characteristic value changes.
    public func setCharacteristicChangeHandler(
        _ handler: @escaping @Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void
    ) {
        onCharacteristicChange = handler
    }

    private static func handlerKey(aid: UInt64, iid: UInt64) -> String {
        "\(aid).\(iid)"
    }

    public init(info: AccessoryInfo, category: HAPCategory = .bridge) {
        self.init(info: info, category: category, saved: nil, store: nil)
    }

    private init(info: AccessoryInfo, category: HAPCategory, saved: BridgeConfiguration?, store: (any BridgeConfigurationStore)?) {
        self.category = category

        // Bridge itself is AID=1
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        let protocolService = HAPService.protocolInformation(startIID: 8)
        let bridge = HAPAccessory(aid: 1, services: [infoService, protocolService])
        self.accessories[1] = bridge
        self.persistedLayout = store == nil ? Self.layoutDescription([bridge]) : saved?.layout
        self.configurationStore = store
        self.configurationNumber = saved?.configurationNumber ?? 1
        self.instanceIDs = saved?.instanceIDs ?? [:]
        self.isBatching = store != nil
        self.batchSnapshot = store == nil ? nil : ([1: bridge], saved?.instanceIDs ?? [:], 2)
    }

    /// Restores c# and stable IID allocations. Provision all accessories, then endBatchUpdate().
    public init(info: AccessoryInfo, category: HAPCategory = .bridge,
                configurationStore: any BridgeConfigurationStore) throws {
        self.init(info: info, category: category, saved: try configurationStore.load(), store: configurationStore)
    }

    // MARK: - Accessory Management

    /// Add an accessory to the bridge.
    ///
    /// - Parameters:
    ///   - info: Accessory metadata (name, manufacturer, etc.).
    ///   - services: HAP services to expose (e.g., lightbulb, motion sensor).
    ///   - aid: Explicit accessory ID. When `nil`, auto-assigns the next available AID.
    ///          Use explicit AIDs for AID stability across restarts.
    /// - Returns: The assigned accessory ID.
    @discardableResult
    public func addAccessory(info: AccessoryInfo, services: [HAPService], aid: UInt64? = nil) async throws -> UInt64 {
        let previous = (accessories, instanceIDs, nextAID)
        guard aid != nil || nextAID < UInt64.max else { throw HAPError.outOfRange }
        guard aid == nil || (aid! > 1 && aid! < UInt64.max) else { throw HAPError.invalidValue }
        let aid: UInt64 = if let explicit = aid {
            explicit
        } else {
            nextAID
        }

        if accessories[aid] != nil {
            logger.warning("Replacing existing accessory at AID=\(aid)")
        }

        // Build accessory information service
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        // Logical keys, not service/characteristic array positions, own IIDs. Removed keys
        // remain as tombstones so later insertions never recycle a paired controller's IID.
        var allServices = [infoService]
        let prefix = "\(aid)/"
        var allocatedIDs = instanceIDs
        var nextIID = max(8, (allocatedIDs.filter { $0.key.hasPrefix(prefix) }.values.max() ?? 7) + 1)
        var seen: Set<String> = []
        func allocate(_ key: String) throws -> UInt64 {
            let key = prefix + key
            if let existing = allocatedIDs[key] { return existing }
            guard nextIID < UInt64.max else { throw HAPError.outOfRange }
            let iid = nextIID
            nextIID += 1
            allocatedIDs[key] = iid
            return iid
        }
        let sortedServices = services.sorted {
            ($0.type.rawValue + "/" + ($0.stableIdentifier ?? "")) < ($1.type.rawValue + "/" + ($1.stableIdentifier ?? ""))
        }
        for service in sortedServices {
            let key = service.type.rawValue + "/" + (service.stableIdentifier ?? "")
            guard seen.insert(key).inserted,
                  Set(service.characteristics.map { $0.type.rawValue }).count == service.characteristics.count else {
                (accessories, instanceIDs, nextAID) = previous
                throw HAPError.invalidValue
            }
            let serviceIID = try allocate(key + "/service")
            let updatedChars = try service.characteristics.sorted { $0.type.rawValue < $1.type.rawValue }.map { char in
                HAPCharacteristic(iid: try allocate(key + "/" + char.type.rawValue), type: char.type, value: char.value,
                                  permissions: char.permissions, format: char.format, minValue: char.minValue,
                                  maxValue: char.maxValue, minStep: char.minStep, unit: char.unit, validValues: char.validValues)
            }
            allServices.append(HAPService(iid: serviceIID, type: service.type, characteristics: updatedChars,
                                          stableIdentifier: service.stableIdentifier))
        }

        let accessory = HAPAccessory(aid: aid, services: allServices)
        accessories[aid] = accessory
        instanceIDs = allocatedIDs
        if aid >= nextAID { nextAID = aid + 1 }

        do { try await incrementAndNotify() }
        catch { (accessories, instanceIDs, nextAID) = previous; throw error }
        return aid
    }

    /// Remove an accessory from the bridge.
    ///
    /// Also cleans up associated write handlers and event subscriptions.
    /// The bridge accessory (AID=1) cannot be removed.
    public func removeAccessory(aid: UInt64) async throws {
        let previous = accessories
        guard aid != 1 else { return }  // Cannot remove bridge
        guard accessories.removeValue(forKey: aid) != nil else { return }
        logger.warning("Removed accessory AID=\(aid). Remaining: \(accessories.keys.sorted())")

        do { try await incrementAndNotify() }
        catch { accessories = previous; throw error }

        // Clean up write handlers for this accessory
        let aidPrefix = "\(aid)."
        writeHandlers = writeHandlers.filter { !$0.key.hasPrefix(aidPrefix) }

        // Clean up event subscriptions for this accessory
        subscriptions = subscriptions.filter { !$0.key.hasPrefix(aidPrefix) }

    }

    // MARK: - Accessory Database

    public func accessoryDatabase() -> [HAPAccessory] {
        accessories.values.sorted { $0.aid < $1.aid }
    }

    // MARK: - Characteristic Access

    public func readCharacteristic(aid: UInt64, iid: UInt64) -> HAPCharacteristicValue? {
        guard let accessory = accessories[aid] else { return nil }
        for service in accessory.services {
            for characteristic in service.characteristics where characteristic.iid == iid {
                return characteristic.value
            }
        }
        return nil
    }

    public func characteristic(aid: UInt64, iid: UInt64) -> HAPCharacteristic? {
        accessories[aid]?.services.flatMap(\.characteristics).first { $0.iid == iid }
    }

    public func writeCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue,
                                    sourceConnectionID: Int? = nil) async throws {
        guard let char = characteristic(aid: aid, iid: iid) else { throw HAPError.notFound }
        guard char.isWritable else { throw HAPError.readOnly }
        let clamped = value.clamped(minValue: char.minValue, maxValue: char.maxValue)
        if let handler = writeHandlers[Self.handlerKey(aid: aid, iid: iid)] {
            try await handler(clamped)
        }
        await updateCharacteristic(aid: aid, iid: iid, value: clamped, excluding: sourceConnectionID)
    }

    // MARK: - Write Handlers

    public func registerWriteHandler(
        aid: UInt64,
        iid: UInt64,
        handler: @escaping @Sendable (HAPCharacteristicValue) async throws -> Void
    ) {
        writeHandlers[Self.handlerKey(aid: aid, iid: iid)] = handler
    }

    // MARK: - Characteristic Updates

    public func updateCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue, excluding connectionID: Int? = nil) async {
        guard var accessory = accessories[aid] else { return }

        for serviceIndex in 0 ..< accessory.services.count {
            for charIndex in 0 ..< accessory.services[serviceIndex].characteristics.count {
                if accessory.services[serviceIndex].characteristics[charIndex].iid == iid {
                    let char = accessory.services[serviceIndex].characteristics[charIndex]
                    let clamped = value.clamped(minValue: char.minValue, maxValue: char.maxValue)
                    let oldValue = char.value
                    accessory.services[serviceIndex].characteristics[charIndex].value = clamped
                    accessories[aid] = accessory

                    // Notify subscribers if value changed
                    if oldValue != clamped {
                        await notifySubscribers(aid: aid, iid: iid, value: clamped, excluding: connectionID)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Event Subscriptions

    public func subscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        guard characteristic(aid: aid, iid: iid)?.supportsNotification == true else { return }
        let key = Self.handlerKey(aid: aid, iid: iid)
        subscriptions[key, default: []].insert(connectionID)
        logger.debug("Event subscribe: connection \(connectionID) → aid=\(aid) iid=\(iid)")
    }

    public func unsubscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        subscriptions[key]?.remove(connectionID)
    }

    /// Remove all subscriptions for a disconnected connection.
    public func unsubscribeAll(connectionID: Int) {
        for key in subscriptions.keys {
            subscriptions[key]?.remove(connectionID)
        }
    }

    private func notifySubscribers(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue, excluding connectionID: Int?) async {
        let key = Self.handlerKey(aid: aid, iid: iid)
        guard let subscribers = subscriptions[key], !subscribers.isEmpty else {
            logger.debug("Event notify: aid=\(aid) iid=\(iid) — no subscribers")
            return
        }
        guard let handler = onCharacteristicChange else {
            logger.warning("Event notify: aid=\(aid) iid=\(iid) — no handler set")
            return
        }

        logger.debug("Event notify: aid=\(aid) iid=\(iid) value=\(value) → \(subscribers.count) subscriber(s)")
        let eventData = Self.buildEventPayload(aid: aid, iid: iid, value: value)
        let subs = subscribers.filter { $0 != connectionID }
        guard !subs.isEmpty else { return }
        await handler(subs, eventData)
    }

    /// Build the raw HTTP bytes for a HAP EVENT/1.0 message.
    ///
    /// Format:
    /// ```
    /// EVENT/1.0 200 OK\r\n
    /// Content-Type: application/hap+json\r\n
    /// Content-Length: <len>\r\n
    /// \r\n
    /// {"characteristics":[{"aid":<aid>,"iid":<iid>,"value":<value>}]}
    /// ```
    private static func buildEventPayload(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue) -> Data {
        let jsonValue: Any = switch value {
        case .bool(let v): v
        case .uint8(let v): v
        case .uint16(let v): v
        case .uint32(let v): v
        case .int32(let v): v
        case .float(let v): v
        case .string(let v): v
        case .data(let v): v.base64EncodedString()
        case .tlv8(let v): v.base64EncodedString()
        }

        let charDict: [String: Any] = ["aid": aid, "iid": iid, "value": jsonValue]
        let body: [String: Any] = ["characteristics": [charDict]]
        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        var event = "EVENT/1.0 200 OK\r\n"
        event += "Content-Type: application/hap+json\r\n"
        event += "Content-Length: \(jsonData.count)\r\n"
        event += "\r\n"

        var data = Data(event.utf8)
        data.append(jsonData)
        return data
    }
}
