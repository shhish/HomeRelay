import Foundation
import HomeKit
import HomeRelayCore
import Synchronization

/// Apple Home through HMHomeManager. Everything touching HomeKit runs on the
/// main actor; HomeKit delivers its delegate callbacks there too.
@MainActor
final class HomeKitStore: NSObject, HomeBackend {
    private let manager: HMHomeManager
    private let events: EventHub
    private let pollInterval: Duration?
    private let sampleInterval: Duration
    private var homesLoaded = false
    /// Characteristics with a notification request in flight.
    private var enabling: Set<UUID> = []
    private var attachTask: Task<Void, Never>?
    /// Notification registrations refused at the last attempt, to log changes only.
    private var lastRefused = 0
    /// Last value seen per characteristic, so polling only reports real changes.
    private var lastValues: [UUID: JSONValue] = [:]
    /// Last value a device reported (notification or re-read), and when it was
    /// recorded; HomeKit sometimes delivers the same notification twice.
    private var lastObserved: [UUID: (value: JSONValue, at: ContinuousClock.Instant)] = [:]
    /// When each characteristic last went into the event log, for samples.
    private var lastRecorded: [UUID: ContinuousClock.Instant] = [:]
    /// A repeated identical notification within this window is a duplicate.
    /// HomeKit's double deliveries arrive together; a wider window could hide a
    /// real repeat when the change in between was never notified.
    private static let duplicateWindow: Duration = .seconds(10)
    /// Characteristics whose notification registration failed, and when to try again.
    private var notifyBackoff: [UUID: ContinuousClock.Instant] = [:]
    private static let notifyRetryAfter: Duration = .seconds(1_800)
    private var pollTask: Task<Void, Never>?
    private var pollCount = 0
    /// Values whose last read failed or timed out, and when to try again. Keeps
    /// one unresponsive device from making every refresh wait for the timeout.
    private var readBackoff: [UUID: ContinuousClock.Instant] = [:]
    private static let readRetryAfter: Duration = .seconds(300)
    /// Every Nth poll re-reads values that claim to notify, for devices that
    /// say they send notifications but don't.
    private static let fullSweepEvery = 20

    private static let readTimeout: Duration = .seconds(6)
    private static let writeTimeout: Duration = .seconds(10)

    init(events: EventHub, pollInterval: Duration?, sampleInterval: Duration) {
        self.events = events
        self.pollInterval = pollInterval
        self.sampleInterval = sampleInterval
        self.manager = HMHomeManager()
        super.init()
        manager.delegate = self
        Log.info("HomeKit authorization status: \(manager.authorizationStatus.rawValue)")
    }

    // MARK: - HomeBackend

    func status() async -> BackendStatus {
        let auth = manager.authorizationStatus
        if !auth.contains(.determined) {
            return BackendStatus(state: "starting", detail: "Waiting for Home access to be allowed on the Mac")
        }
        if !auth.contains(.authorized) {
            return BackendStatus(state: "notAuthorized", detail: "Home access is off for HomeRelay in System Settings > Privacy & Security > Home")
        }
        if !homesLoaded { return BackendStatus(state: "starting") }
        if manager.homes.isEmpty { return BackendStatus(state: "noHomes") }
        return BackendStatus(state: "ready")
    }

    func homes() async throws -> [HomeSummary] {
        try await ready()
        return manager.homes.map {
            HomeSummary(
                id: $0.uniqueIdentifier.uuidString, name: $0.name, rooms: $0.rooms.count,
                accessories: $0.accessories.count, scenes: Self.userScenes($0).count
            )
        }
    }

    func snapshot(home: String?, refresh: Bool) async throws -> [HomeDTO] {
        let homes = try await selectHomes(home)
        if refresh { await read(homes.flatMap(\.accessories)) }
        return homes.map { h in
            HomeDTO(
                id: h.uniqueIdentifier.uuidString, name: h.name,
                rooms: roomDTOs(h), accessories: h.accessories.map { dto($0, in: h) }, scenes: sceneDTOs(h)
            )
        }
    }

    func rooms(home: String?) async throws -> [RoomDTO] {
        try await selectHomes(home).flatMap(roomDTOs)
    }

    func accessories(home: String?, room: String?, category: String?, refresh: Bool) async throws -> [AccessoryDTO] {
        var pairs: [(HMAccessory, HMHome)] = []
        for h in try await selectHomes(home) {
            for a in h.accessories {
                if let room, (a.room?.name ?? "").caseInsensitiveCompare(room) != .orderedSame { continue }
                // Filter on the category clients see, which is inferred from services.
                if let category, Self.inferredCategory(a) != category { continue }
                pairs.append((a, h))
            }
        }
        if refresh { await read(pairs.map(\.0)) }
        return pairs.map { dto($0.0, in: $0.1) }
    }

    func accessory(_ ref: String, home: String?, refresh: Bool) async throws -> AccessoryDTO {
        let (a, h) = try await resolveAccessory(ref, home: home)
        if refresh { await read([a]) }
        return dto(a, in: h)
    }

    func setAccessory(_ ref: String, home: String?, values: [String: JSONValue]) async throws -> AccessoryDTO {
        let (a, h) = try await resolveAccessory(ref, home: home)
        for write in try WritePlanner.plan(values, for: dto(a, in: h)) {
            try await perform(write)
        }
        return dto(a, in: h)
    }

    func toggleAccessory(_ ref: String, home: String?) async throws -> AccessoryDTO {
        let (a, h) = try await resolveAccessory(ref, home: home)
        await read([a])
        try await perform(try WritePlanner.toggle(dto(a, in: h)))
        return dto(a, in: h)
    }

    func writeCharacteristic(id: String, value: JSONValue) async throws -> CharacteristicDTO {
        try await ready()
        guard let uuid = UUID(uuidString: id), let found = findCharacteristic(uuid) else {
            throw APIError.notFound("No characteristic with id \(id)")
        }
        let current = characteristicDTO(found.characteristic)
        guard current.writable else { throw APIError.unprocessable("'\(current.label)' is read-only") }
        try await perform(PlannedWrite(characteristicId: id, type: current.type, value: try ValueCoercion.coerce(value, to: current.spec)))
        return characteristicDTO(found.characteristic)
    }

    func scenes(home: String?) async throws -> [SceneDTO] {
        try await selectHomes(home).flatMap(sceneDTOs)
    }

    func runScene(_ ref: String, home: String?) async throws -> SceneDTO {
        let homes = try await selectHomes(home)
        let all = homes.flatMap { h in Self.userScenes(h).map { (h, $0) } }
        let named = try RefResolver.resolve(ref, in: all.map { Named(id: $0.1.uniqueIdentifier.uuidString, name: $0.1.name, room: $0.0.name) }, kind: "scene")
        guard let (h, scene) = all.first(where: { $0.1.uniqueIdentifier.uuidString == named.id }) else {
            throw APIError.notFound("Scene vanished: \(ref)")
        }
        try await Self.withTimeout(Self.writeTimeout, "Running '\(scene.name)'") {
            try await h.executeActionSet(scene)
        }
        // HomeKit does not notify the app that ran a scene, so report the
        // targets the scene set.
        for case let action as HMCharacteristicWriteAction<NSCopying> in scene.actions {
            publishChange(action.characteristic, value: Self.json(action.targetValue, format: action.characteristic.metadata?.format),
                          origin: "scene", scene: scene.name)
        }
        Log.info("Ran scene \(scene.name)")
        return SceneDTO(id: named.id, name: scene.name, home: h.name, kind: HomeKitNames.sceneKind(scene.actionSetType))
    }

    /// HomeKit metadata for history: how to summarise each characteristic.
    func seriesMeta(_ ids: [String]) -> [String: SeriesMeta] {
        var out: [String: SeriesMeta] = [:]
        for id in ids {
            guard let uuid = UUID(uuidString: id), let found = findCharacteristic(uuid) else { continue }
            let c = found.characteristic
            let m = c.metadata
            out[id] = SeriesMeta(
                type: HomeKitNames.characteristic(c), format: m?.format, unit: m?.units,
                validValues: m?.validValues?.map(\.intValue), min: m?.minimumValue?.doubleValue, max: m?.maximumValue?.doubleValue
            )
        }
        return out
    }

    // MARK: - Selection

    private func ready() async throws {
        let s = await status()
        if !s.isReady { throw APIError.unavailable(s.detail ?? "HomeKit is \(s.state)") }
    }

    private func selectHomes(_ ref: String?) async throws -> [HMHome] {
        try await ready()
        guard let ref else { return manager.homes }
        let named = try RefResolver.resolve(ref, in: manager.homes.map { Named(id: $0.uniqueIdentifier.uuidString, name: $0.name) }, kind: "home")
        return manager.homes.filter { $0.uniqueIdentifier.uuidString == named.id }
    }

    private func resolveAccessory(_ ref: String, home: String?) async throws -> (HMAccessory, HMHome) {
        let pairs = try await selectHomes(home).flatMap { h in h.accessories.map { ($0, h) } }
        let named = try RefResolver.resolve(ref, in: pairs.map { Named(id: $0.0.uniqueIdentifier.uuidString, name: $0.0.name, room: $0.0.room?.name) }, kind: "accessory")
        return pairs.first { $0.0.uniqueIdentifier.uuidString == named.id }!
    }

    private func findCharacteristic(_ id: UUID) -> (characteristic: HMCharacteristic, accessory: HMAccessory)? {
        for h in manager.homes {
            for a in h.accessories {
                for s in a.services {
                    if let c = s.characteristics.first(where: { $0.uniqueIdentifier == id }) { return (c, a) }
                }
            }
        }
        return nil
    }

    // MARK: - Reads and writes

    /// Refreshes readable values on reachable accessories. Values HomeKit keeps
    /// current through change notifications are trusted unless `force` is set:
    /// reading them anyway is slow (battery sensors take seconds to wake) and
    /// drains those sensors. Slow devices are skipped after a timeout rather
    /// than failing the request.
    ///
    /// Battery accessories are only read for values never seen before: their
    /// slow-changing values (battery level, status) usually lack notifications,
    /// and each read wakes the sensor. Vendor values are never read; many (Eve
    /// history logs, for one) don't answer plain reads at all.
    private func read(_ accessories: [HMAccessory], force: Bool = false) async {
        let now = ContinuousClock.now
        readBackoff = readBackoff.filter { $0.value > now }
        let targets = accessories
            .filter(\.isReachable)
            .flatMap { a in
                let battery = Self.hasBattery(a)
                return a.services
                    .filter { $0.serviceType != HMServiceTypeAccessoryInformation }
                    .flatMap(\.characteristics)
                    .filter { Self.isEventWorthy($0) && $0.properties.contains(HMCharacteristicPropertyReadable) }
                    .filter { readBackoff[$0.uniqueIdentifier] == nil }
                    .filter { c in
                        if c.value == nil { return true }
                        if battery { return false }
                        return force || !c.isNotificationEnabled
                    }
            }
        let failed = await withTaskGroup(of: UUID?.self) { group in
            for c in targets {
                group.addTask {
                    do {
                        try await Self.withTimeout(Self.readTimeout, "Reading \(c.localizedDescription)") {
                            try await c.readValue()
                        }
                        return nil
                    } catch {
                        return c.uniqueIdentifier
                    }
                }
            }
            var failed: [UUID] = []
            for await id in group { if let id { failed.append(id) } }
            return failed
        }
        let retryAt = ContinuousClock.now + Self.readRetryAfter
        for id in failed { readBackoff[id] = retryAt }
    }

    private func perform(_ write: PlannedWrite) async throws {
        guard let uuid = UUID(uuidString: write.characteristicId), let found = findCharacteristic(uuid) else {
            throw APIError.notFound("No characteristic with id \(write.characteristicId)")
        }
        let c = found.characteristic
        let value: any Sendable = switch write.value {
        case .bool(let v): NSNumber(value: v)
        case .int(let v): NSNumber(value: v)
        case .double(let v): NSNumber(value: v)
        case .string(let v): v
        }
        do {
            try await Self.withTimeout(Self.writeTimeout, "Setting \(write.type) on \(found.accessory.name)") {
                try await c.writeValue(value)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.deviceFailed("\(found.accessory.name) did not accept \(write.type): \(error.localizedDescription)")
        }
        Log.info("Set \(found.accessory.name).\(write.type)")
        // HomeKit does not echo our own writes back through the delegate.
        publishChange(c, value: write.value.json, origin: "write")
    }

    /// Runs `operation` but stops waiting after `limit`. HomeKit calls are not
    /// cancellable, so a timed-out call is left to finish in the background.
    nonisolated private static func withTimeout(
        _ limit: Duration, _ what: String, _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let settled = SettleOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            @Sendable func settle(_ result: Result<Void, any Error>) {
                if settled.claim() { continuation.resume(with: result) }
            }
            Task {
                do { try await operation(); settle(.success(())) } catch { settle(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                settle(.failure(APIError.timedOut("\(what) took longer than \(limit)")))
            }
        }
    }

    // MARK: - Events

    /// Logs and streams a characteristic value. `origin` says where it came
    /// from (see `HomeEvent.origin`); writes and scenes are labelled with the
    /// token and cause of the request that made them.
    private func publishChange(_ c: HMCharacteristic, value: JSONValue?, origin: String, scene: String? = nil) {
        guard let service = c.service, let accessory = service.accessory else { return }
        let type = HomeKitNames.characteristic(c)
        // Vendor values are mostly counters and diagnostics; streaming them is noise.
        guard !AccessoryDTO.isCustom(type) else { return }
        let now = ContinuousClock.now
        let observed = origin == "notification" || origin == "poll"
        if origin == "notification", let value, type != "buttonEvent",
           let last = lastObserved[c.uniqueIdentifier], last.value == value, now - last.at < Self.duplicateWindow {
            return
        }
        if let value {
            lastValues[c.uniqueIdentifier] = value
            if observed { lastObserved[c.uniqueIdentifier] = (value, now) }
        }
        lastRecorded[c.uniqueIdentifier] = now
        let fromRequest = origin == "write" || origin == "scene"
        events.publish(HomeEvent(
            type: "characteristic",
            home: home(of: accessory)?.name,
            accessoryId: accessory.uniqueIdentifier.uuidString,
            accessory: accessory.name,
            room: accessory.room?.name,
            serviceId: service.uniqueIdentifier.uuidString,
            characteristicId: c.uniqueIdentifier.uuidString,
            characteristic: type,
            value: value,
            origin: origin,
            by: fromRequest ? RequestContext.caller : nil,
            scene: scene,
            cause: fromRequest ? RequestContext.cause : nil
        ))
    }

    /// Logs (without streaming) an unchanged value when nothing about it has
    /// been recorded for `sampleInterval`, so history can tell a steady value
    /// from missing data.
    private func sampleIfDue(_ c: HMCharacteristic, value: JSONValue, in accessory: HMAccessory) {
        let now = ContinuousClock.now
        if let last = lastRecorded[c.uniqueIdentifier], now - last < sampleInterval { return }
        let type = HomeKitNames.characteristic(c)
        guard type != "buttonEvent", !History.unrecordedTypes.contains(type), let service = c.service else { return }
        lastRecorded[c.uniqueIdentifier] = now
        events.record(HomeEvent(
            type: "characteristic",
            home: home(of: accessory)?.name,
            accessoryId: accessory.uniqueIdentifier.uuidString,
            accessory: accessory.name,
            room: accessory.room?.name,
            serviceId: service.uniqueIdentifier.uuidString,
            characteristicId: c.uniqueIdentifier.uuidString,
            characteristic: type,
            value: value,
            origin: "sample"
        ))
    }

    private func publishHomes(_ home: HMHome? = nil, _ accessory: HMAccessory? = nil) {
        events.publish(HomeEvent(type: "homes", home: home?.name, accessoryId: accessory?.uniqueIdentifier.uuidString, accessory: accessory?.name))
    }

    private func home(of accessory: HMAccessory) -> HMHome? {
        manager.homes.first { $0.accessories.contains { $0.uniqueIdentifier == accessory.uniqueIdentifier } }
    }

    /// Coalesces bursts of HomeKit graph changes into one `attach`.
    private func scheduleAttach() {
        attachTask?.cancel()
        attachTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.attach()
        }
    }

    /// Hooks delegates and change notifications on every accessory. Safe to
    /// repeat: HomeKit can replace accessory objects or drop notification
    /// registrations (after a hub restart, say), so this re-enables whatever
    /// isn't enabled, in small batches so a large home doesn't flood HomeKit.
    private func attach() async {
        let now = ContinuousClock.now
        notifyBackoff = notifyBackoff.filter { $0.value > now }
        var wanted: [(HMCharacteristic, HMAccessory)] = []
        for h in manager.homes {
            h.delegate = self
            for a in h.accessories {
                a.delegate = self
                guard a.isReachable else { continue }
                for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation {
                    for c in s.characteristics where Self.isEventWorthy(c)
                        && c.properties.contains(HMCharacteristicPropertySupportsEventNotification)
                        && !c.isNotificationEnabled && !enabling.contains(c.uniqueIdentifier)
                        && notifyBackoff[c.uniqueIdentifier] == nil {
                        wanted.append((c, a))
                    }
                }
            }
        }
        guard !wanted.isEmpty else { return }
        for (c, _) in wanted { enabling.insert(c.uniqueIdentifier) }
        var failed = 0
        for batch in stride(from: 0, to: wanted.count, by: 16).map({ Array(wanted[$0..<min($0 + 16, wanted.count)]) }) {
            let refused = await withTaskGroup(of: UUID?.self) { group in
                for (c, _) in batch {
                    group.addTask {
                        do {
                            try await Self.withTimeout(Self.readTimeout, "Enabling notifications") {
                                try await c.enableNotification(true)
                            }
                            return nil
                        } catch {
                            return c.uniqueIdentifier
                        }
                    }
                }
                var refused: [UUID] = []
                for await id in group { if let id { refused.append(id) } }
                return refused
            }
            failed += refused.count
            let retryAt = ContinuousClock.now + Self.notifyRetryAfter
            for id in refused { notifyBackoff[id] = retryAt }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for (c, _) in wanted { enabling.remove(c.uniqueIdentifier) }
        // Some devices refuse every time; say so when the picture changes, not every sweep.
        if wanted.count > failed || failed != lastRefused {
            Log.info("Enabled change notifications on \(wanted.count - failed) characteristics"
                + (failed > 0 ? "; \(failed) refused or timed out, retried in 30 minutes" : ""))
        }
        lastRefused = failed
    }

    /// Fallback for devices that do not send notifications: re-read on a slow
    /// interval and report anything that changed.
    private func startPolling() {
        guard let interval = pollInterval, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.pollCount += 1
                await self.pollOnce(fullSweep: self.pollCount % Self.fullSweepEvery == 0)
            }
        }
    }

    /// A full sweep re-reads mains-powered accessories completely and repairs
    /// notification registrations; battery accessories are left to their
    /// notifications.
    private func pollOnce(fullSweep: Bool) async {
        let accessories = manager.homes.flatMap(\.accessories)
        if fullSweep {
            await read(accessories.filter { !Self.hasBattery($0) }, force: true)
        } else {
            await read(accessories)
        }
        diff(accessories)
        if fullSweep { await attach() }
    }

    /// Publishes values that changed since last seen and samples the rest.
    private func diff(_ accessories: [HMAccessory]) {
        for a in accessories where a.isReachable {
            for s in a.services where s.serviceType != HMServiceTypeAccessoryInformation {
                for c in s.characteristics where Self.isEventWorthy(c) && c.properties.contains(HMCharacteristicPropertyReadable) {
                    guard let value = Self.json(c.value, format: c.metadata?.format) else { continue }
                    if let previous = lastValues[c.uniqueIdentifier], previous != value {
                        publishChange(c, value: value, origin: "poll")
                    } else {
                        // First sight (the session's starting state) or unchanged.
                        lastValues[c.uniqueIdentifier] = value
                        sampleIfDue(c, value: value, in: a)
                    }
                }
            }
        }
    }

    /// An accessory that comes back may have changed while away, and may have
    /// lost its notification registrations.
    private func refreshReturning(_ a: HMAccessory) async {
        let ids = Set(a.services.flatMap(\.characteristics).map(\.uniqueIdentifier))
        readBackoff = readBackoff.filter { !ids.contains($0.key) }
        notifyBackoff = notifyBackoff.filter { !ids.contains($0.key) }
        await read([a], force: !Self.hasBattery(a))
        diff([a])
        await attach()
    }

    // MARK: - DTOs

    private static func inferredCategory(_ a: HMAccessory) -> String {
        let ordered = a.services.filter(\.isPrimaryService) + a.services.filter { !$0.isPrimaryService }
        return CategoryInference.infer(reported: HomeKitNames.category(a.category), serviceTypes: ordered.map(HomeKitNames.service))
    }

    private func dto(_ a: HMAccessory, in h: HMHome) -> AccessoryDTO {
        let services = a.services.map { s in
            ServiceDTO(
                id: s.uniqueIdentifier.uuidString,
                type: HomeKitNames.service(s),
                name: s.name,
                primary: s.isPrimaryService,
                characteristics: s.characteristics.filter(Self.isVisible).map(characteristicDTO)
            )
        }
        let serviceTypes = (services.filter(\.primary) + services.filter { !$0.primary }).map(\.type)
        return AccessoryDTO(
            id: a.uniqueIdentifier.uuidString,
            name: a.name,
            home: h.name,
            room: a.room?.name,
            category: CategoryInference.infer(reported: HomeKitNames.category(a.category), serviceTypes: serviceTypes),
            reachable: a.isReachable,
            bridged: a.isBridged,
            manufacturer: a.manufacturer,
            model: a.model,
            services: services
        )
    }

    private func characteristicDTO(_ c: HMCharacteristic) -> CharacteristicDTO {
        let m = c.metadata
        return CharacteristicDTO(
            id: c.uniqueIdentifier.uuidString,
            type: HomeKitNames.characteristic(c),
            label: c.localizedDescription,
            value: Self.json(c.value, format: m?.format),
            format: m?.format,
            unit: m?.units,
            min: m?.minimumValue?.doubleValue,
            max: m?.maximumValue?.doubleValue,
            step: m?.stepValue?.doubleValue,
            validValues: m?.validValues?.map(\.intValue),
            readable: c.properties.contains(HMCharacteristicPropertyReadable),
            writable: c.properties.contains(HMCharacteristicPropertyWritable),
            notifies: c.properties.contains(HMCharacteristicPropertySupportsEventNotification)
        )
    }

    private func roomDTOs(_ h: HMHome) -> [RoomDTO] {
        let entire = h.roomForEntireHome()
        return ([entire] + h.rooms).compactMap { r in
            let ids = r.accessories.map(\.uniqueIdentifier.uuidString)
            if r == entire && ids.isEmpty { return nil }
            return RoomDTO(id: r.uniqueIdentifier.uuidString, name: r.name, home: h.name, accessoryIds: ids)
        }
    }

    private func sceneDTOs(_ h: HMHome) -> [SceneDTO] {
        Self.userScenes(h).map {
            SceneDTO(id: $0.uniqueIdentifier.uuidString, name: $0.name, home: h.name, kind: HomeKitNames.sceneKind($0.actionSetType))
        }
    }

    /// Scenes as the Home app shows them; automation-owned action sets are hidden.
    private static func userScenes(_ h: HMHome) -> [HMActionSet] {
        h.actionSets.filter { $0.actionSetType != HMActionSetTypeTriggerOwned }
    }

    private static func isVisible(_ c: HMCharacteristic) -> Bool {
        !c.properties.contains(HMCharacteristicPropertyHidden)
    }

    private static func hasBattery(_ a: HMAccessory) -> Bool {
        a.services.contains { $0.serviceType == HMServiceTypeBattery }
    }

    private static func isEventWorthy(_ c: HMCharacteristic) -> Bool {
        isVisible(c) && !AccessoryDTO.isCustom(HomeKitNames.characteristic(c))
    }

    static func json(_ value: Any?, format: String?) -> JSONValue? {
        guard let value else { return nil }
        switch value {
        case let n as NSNumber:
            switch format {
            case HMCharacteristicMetadataFormatBool: return .bool(n.boolValue)
            // Devices send float32, so 22.7 arrives as 22.700000762939453.
            case HMCharacteristicMetadataFormatFloat: return .double((n.doubleValue * 10_000).rounded() / 10_000)
            case HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
                 HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64:
                return .int(n.intValue)
            default:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
            }
        case let s as String:
            return .string(s)
        case let d as Data:
            return .string(d.base64EncodedString())
        case let list as [Any]:
            return .array(list.compactMap { json($0, format: nil) })
        default:
            return .string(String(describing: value))
        }
    }
}

/// Lets exactly one of several racing callbacks win.
private final class SettleOnce: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

// MARK: - HomeKit delegates

extension HomeKitStore: HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            let first = !self.homesLoaded
            self.homesLoaded = true
            Log.info("HomeKit has \(manager.homes.count) home(s), \(manager.homes.reduce(0) { $0 + $1.accessories.count }) accessories")
            if first {
                Task { await self.attach() }
                await self.pollOnce(fullSweep: true)
                self.startPolling()
            } else {
                self.scheduleAttach()
            }
            self.publishHomes()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Log.info("HomeKit authorization status changed: \(status.rawValue)")
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor in
            self.scheduleAttach()
            self.publishHomes(home, accessory)
        }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes(home, accessory) }
    }

    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes(home, accessory) }
    }

    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes(self.home(of: accessory), accessory) }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor in
            self.scheduleAttach()
            self.publishHomes(self.home(of: accessory), accessory)
        }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor in
            self.publishChange(characteristic, value: Self.json(characteristic.value, format: characteristic.metadata?.format), origin: "notification")
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor in
            self.events.publish(HomeEvent(
                type: "reachability",
                home: self.home(of: accessory)?.name,
                accessoryId: accessory.uniqueIdentifier.uuidString,
                accessory: accessory.name,
                room: accessory.room?.name,
                reachable: accessory.isReachable
            ))
            if accessory.isReachable { await self.refreshReturning(accessory) }
        }
    }
}
