import Foundation
import HAPApple
import HAPCore
import HAPCrypto
import HAPTransport
import HomeRelayCore

/// Publishes HomeRelay's States into Apple Home as accessories on one HomeKit
/// bridge. A switch State can be flipped from the Home app or Siri; a sensor
/// State can trigger Apple Home automations. The owner pairs the bridge once.
///
/// Identity, pairings and the accessory layout persist in `directory`, so the
/// pairing survives restarts and updates. Each State keeps the accessory id it
/// was given when created, so the Home app keeps its room and automations.
actor StateBridge {
    struct Status: Encodable, Sendable {
        var running: Bool
        var paired: Bool
        var port: Int
        var accessories: Int
        /// Only while unpaired: the 8-digit code to type in the Home app.
        var setupCode: String?
        /// Only while unpaired: the `X-HM://` payload to render as a QR code.
        var setupURI: String?
        var error: String?
    }

    private struct Published {
        var aid: UInt64
        var iid: UInt64
        var kind: String
        var value: HAPCharacteristicValue
    }

    private let directory: URL
    private let port: UInt16
    private let states: StateStore
    private var lock: StorageDirectoryLock?
    private var pairings: FilePairingStore?
    private var bridge: HAPBridge?
    private var service: AppleHAPService?
    private var identity: AccessoryIdentity?
    private var published: [String: Published] = [:]
    private var lastError: String?

    init(directory: URL, port: Int, states: StateStore) {
        self.directory = directory
        self.port = UInt16(clamping: port)
        self.states = states
    }

    /// Starts the bridge, retrying every minute (backing off to ten) while it
    /// can't, for example while its port is taken. `/health/bridge` answers 503
    /// meanwhile.
    func start() async {
        var delay: Duration = .seconds(60)
        while !(await attempt()) {
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(600))
        }
    }

    private func attempt() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lock = try StorageDirectoryLock(directory: directory)
            let pairings = try FilePairingStore(url: directory.appending(path: "pairings.json"))
            self.pairings = pairings
            // A paired bridge must never mint a new identity: that would orphan the pairing.
            let paired = await pairings.isPaired
            // The store insists on the same setup code every launch; it's saved with the identity.
            let identityURL = directory.appending(path: "identity.json")
            let code = (try? Data(contentsOf: identityURL))
                .flatMap { try? JSONDecoder().decode(AccessoryIdentity.self, from: $0) }?.setupCode
                ?? AccessoryIdentity.generateSetupCode()
            let saved = try await FileAccessoryIdentityStore(url: identityURL, allowsCreation: !paired)
                .loadOrCreate(setupCode: code)
            identity = saved
            let bridge = try HAPBridge(
                info: Self.info("HomeRelay States", serial: "homerelay-bridge"),
                configurationStore: FileBridgeConfigurationStore(url: directory.appending(path: "layout.json"))
            )
            self.bridge = bridge
            for state in await states.list() { try await add(state, to: bridge) }
            try await bridge.endBatchUpdate()
            let service = AppleHAPService(
                bridge: bridge, setupCode: saved.setupCode, deviceID: saved.deviceID, setupID: saved.setupID,
                identity: try saved.identity, pairingStore: pairings
            )
            try await service.start(port: port)
            self.service = service
            await states.observe { [weak self] list in
                Task { await self?.sync(list) }
            }
            Log.info("HomeKit bridge on port \(port) with \(published.count) States; \(paired ? "paired" : "waiting to be paired")")
            lastError = nil
            return true
        } catch {
            let message = Self.explain(error)
            if message != lastError { Log.error("HomeKit bridge failed to start: \(message); retrying") }
            lastError = message
            // Release everything so the next attempt starts clean.
            await service?.stop()
            service = nil
            bridge = nil
            pairings = nil
            published = [:]
            lock = nil
            return false
        }
    }

    /// The Bonjour refusal macOS gives when Local Network access is off. macOS
    /// decides that once per process, so allowing it later needs a relaunch.
    private static func explain(_ error: Error) -> String {
        let text = "\(error)"
        return text.contains("-65555")
            ? "Bonjour refused (\(text)): allow HomeRelay under System Settings → Privacy & Security → Local Network, then restart HomeRelay"
            : text
    }

    func status() async -> Status {
        let paired = await pairings?.isPaired ?? false
        return Status(
            running: service != nil, paired: paired, port: Int(port), accessories: published.count,
            setupCode: paired ? nil : identity?.setupCode,
            setupURI: paired ? nil : identity.flatMap { Self.setupURI(setupCode: $0.setupCode, setupID: $0.setupID) },
            error: lastError
        )
    }

    /// Brings the bridge in line with the States: new ones appear, deleted ones
    /// go, and changed values reach every paired controller.
    private func sync(_ list: [VirtualState]) async {
        guard let bridge else { return }
        let ids = Set(list.map(\.id))
        let removed = published.keys.filter { !ids.contains($0) }
        let added = list.filter { published[$0.id] == nil }
        do {
            if !removed.isEmpty || !added.isEmpty {
                await bridge.beginBatchUpdate()
                for id in removed {
                    if let p = published.removeValue(forKey: id) { try await bridge.removeAccessory(aid: p.aid) }
                }
                for state in added { try await add(state, to: bridge) }
                try await bridge.endBatchUpdate()
            }
        } catch {
            lastError = "\(error)"
            Log.error("HomeKit bridge layout change failed: \(error)")
        }
        for state in list {
            guard var p = published[state.id] else { continue }
            let value = Self.value(for: state)
            if value != p.value {
                await bridge.updateCharacteristic(aid: p.aid, iid: p.iid, value: value)
                p.value = value
                published[state.id] = p
            }
        }
    }

    private func add(_ state: VirtualState, to bridge: HAPBridge) async throws {
        let (service, type): (HAPService, HAPCharacteristicType) = switch state.kind {
        case "contact": (.contactSensor(startIID: 1), .contactSensorState)
        case "motion": (.motionSensor(startIID: 1), .motionDetected)
        case "occupancy": (.occupancySensor(startIID: 1), .occupancyDetected)
        case "leak": (.leakSensor(startIID: 1), .leakDetected)
        default: (.switch(startIID: 1), .on)
        }
        let aid = UInt64(state.aid)
        _ = try await bridge.addAccessory(info: Self.info(state.name, serial: "state-\(state.aid)"), services: [service], aid: aid)
        // The bridge assigns IIDs; look ours up rather than assuming the factory's.
        guard let iid = await bridge.accessoryDatabase().first(where: { $0.aid == aid })?
            .services.flatMap(\.characteristics).first(where: { $0.type == type })?.iid else {
            throw HAPError.notFound
        }
        let value = Self.value(for: state)
        await bridge.updateCharacteristic(aid: aid, iid: iid, value: value)
        published[state.id] = Published(aid: aid, iid: iid, kind: state.kind, value: value)
        if state.kind == "switch" {
            let states = self.states
            let id = state.id
            await bridge.registerWriteHandler(aid: aid, iid: iid) { [weak self] value in
                guard case .bool(let on) = value else { throw HAPError.invalidValue }
                try await states.set(id, on: on, by: "home-app", origin: "bridge")
                await self?.remember(id, .bool(on))
            }
        }
    }

    private func remember(_ id: String, _ value: HAPCharacteristicValue) {
        published[id]?.value = value
    }

    private static func value(for state: VirtualState) -> HAPCharacteristicValue {
        switch state.kind {
        case "contact": .uint8(state.on ? 1 : 0)  // on = open (contact not detected)
        case "motion": .bool(state.on)
        case "occupancy", "leak": .uint8(state.on ? 1 : 0)
        default: .bool(state.on)
        }
    }

    private static func info(_ name: String, serial: String) -> AccessoryInfo {
        AccessoryInfo(name: name, manufacturer: "HomeRelay", model: "State", serialNumber: serial, firmwareRevision: "1.0")
    }

    /// The `X-HM://` payload the Home app scans (HAP 5.10.3): category << 31 |
    /// IP transport flag << 27 | setup code, base36 in 9 characters, then the
    /// setup id. Adapted from Itsyhome (MIT), macOSBridge/HAPBridge/HAPSetupQRCode.swift.
    static func setupURI(setupCode: String, setupID: String) -> String? {
        let digits = setupCode.filter(\.isNumber)
        guard digits.count == 8, let code = UInt64(digits) else { return nil }
        let payload: UInt64 = 2 << 31 | 2 << 27 | code
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = payload
        var out = ""
        while value > 0 {
            out = String(alphabet[Int(value % 36)]) + out
            value /= 36
        }
        return "X-HM://" + String(repeating: "0", count: max(0, 9 - out.count)) + out + setupID
    }
}
