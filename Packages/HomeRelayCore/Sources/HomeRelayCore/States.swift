import Foundation

/// A virtual accessory: a named on/off value that HomeRelay keeps, such as
/// "Guest mode" or "Garage open too long". Clients and routines set States
/// through the API; the HomeKit bridge publishes them into Apple Home, where a
/// switch State can be flipped from the Home app or Siri and a sensor State
/// can trigger Apple Home automations.
public struct VirtualState: Codable, Sendable, Equatable {
    /// Stable slug, derived from the first name; never reused.
    public var id: String
    public var name: String
    /// `switch` (settable in the Home app), or a sensor: `contact`, `motion`, `occupancy`, `leak`.
    public var kind: String
    public var on: Bool
    /// Turns itself off this many seconds after being turned on.
    public var resetAfter: Int?
    public var updatedAt: String
    public var updatedBy: String?
    /// HomeKit accessory id on the bridge; assigned once, never reused.
    public var aid: Int

    public static let kinds: Set<String> = ["switch", "contact", "motion", "occupancy", "leak"]
    /// HomeKit allows 150 accessories per bridge, one of which is the bridge.
    public static let limit = 149

    /// The accessory and characteristic ids States use on the event stream and in history.
    public var accessoryId: String { "state:\(id)" }
    public var characteristicId: String { "state:\(id):on" }
}

/// Persists States in a JSON file (atomic writes, owner-only) and publishes
/// every change as a `characteristic` event on accessory `state:<id>`, so the
/// event log, history and routines treat States like any device.
public actor StateStore {
    private struct File: Codable {
        var states: [VirtualState] = []
        /// Highest bridge accessory id handed out (1 is the bridge itself).
        var lastAid = 1
    }

    private let path: URL
    private let hub: EventHub
    private var file = File()
    private var resets: [String: Task<Void, Never>] = [:]
    private var observers: [@Sendable ([VirtualState]) -> Void] = []

    public init(path: URL, hub: EventHub) throws {
        self.path = path
        self.hub = hub
        if FileManager.default.fileExists(atPath: path.path) {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: path))
        }
    }

    /// Restarts reset timers for States left on (a restart doesn't keep them on forever).
    public func start() {
        for state in file.states where state.on && state.resetAfter != nil {
            scheduleReset(state)
        }
    }

    /// Called with the full list after every change (the bridge uses this).
    public func observe(_ observer: @escaping @Sendable ([VirtualState]) -> Void) {
        observers.append(observer)
        observer(file.states)
    }

    public func list() -> [VirtualState] { file.states }

    public func get(_ ref: String) throws(APIError) -> VirtualState {
        file.states[try index(ref)]
    }

    public func create(name rawName: String, kind: String, resetAfter: Int?, by: String?) throws(APIError) -> VirtualState {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else { throw .badRequest("name must be 1 to 64 characters") }
        guard VirtualState.kinds.contains(kind) else {
            throw .badRequest("kind must be one of \(VirtualState.kinds.sorted().joined(separator: ", "))")
        }
        if let resetAfter, !(1...86_400).contains(resetAfter) { throw .badRequest("resetAfter must be 1 to 86400 seconds") }
        guard file.states.count < VirtualState.limit else { throw .unprocessable("At most \(VirtualState.limit) States fit on one HomeKit bridge") }
        guard !file.states.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw APIError(status: 409, code: "exists", message: "A State named '\(name)' already exists")
        }
        var id = Self.slug(name)
        var n = 2
        while file.states.contains(where: { $0.id == id }) { id = "\(Self.slug(name))-\(n)"; n += 1 }
        file.lastAid += 1
        let state = VirtualState(id: id, name: name, kind: kind, on: false, resetAfter: resetAfter,
                                 updatedAt: HomeEvent.now(), updatedBy: by, aid: file.lastAid)
        file.states.append(state)
        try save()
        hub.publish(HomeEvent(type: "homes", accessoryId: state.accessoryId, accessory: state.name))
        notify()
        return state
    }

    /// Sets a State. `origin` is `write` for API clients and `bridge` for the Home app.
    @discardableResult
    public func set(_ ref: String, on: Bool, by: String?, cause: String? = nil, origin: String = "write") throws(APIError) -> VirtualState {
        let i = try index(ref)
        let changed = file.states[i].on != on
        file.states[i].on = on
        file.states[i].updatedAt = HomeEvent.now()
        file.states[i].updatedBy = by
        try save()
        let state = file.states[i]
        resets[state.id]?.cancel()
        resets[state.id] = nil
        if on, state.resetAfter != nil { scheduleReset(state) }
        if changed || origin != "reset" {
            hub.publish(event(for: state, origin: origin, by: by, cause: cause))
        }
        notify()
        return state
    }

    public func update(_ ref: String, name: String?, resetAfter: Int??) throws(APIError) -> VirtualState {
        let i = try index(ref)
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(trimmed.count) else { throw .badRequest("name must be 1 to 64 characters") }
            guard !file.states.enumerated().contains(where: { $0.offset != i && $0.element.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw APIError(status: 409, code: "exists", message: "A State named '\(trimmed)' already exists")
            }
            file.states[i].name = trimmed
        }
        if let resetAfter { file.states[i].resetAfter = resetAfter }
        try save()
        hub.publish(HomeEvent(type: "homes", accessoryId: file.states[i].accessoryId, accessory: file.states[i].name))
        notify()
        return file.states[i]
    }

    public func delete(_ ref: String) throws(APIError) {
        let i = try index(ref)
        let state = file.states.remove(at: i)
        resets[state.id]?.cancel()
        resets[state.id] = nil
        try save()
        hub.publish(HomeEvent(type: "homes", accessoryId: state.accessoryId, accessory: state.name))
        notify()
    }

    // MARK: - Helpers

    private func index(_ ref: String) throws(APIError) -> Int {
        let key = ref.hasPrefix("state:") ? String(ref.dropFirst(6)) : ref
        if let i = file.states.firstIndex(where: { $0.id == key }) { return i }
        if let i = file.states.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return i }
        throw .notFound("No State '\(ref)'")
    }

    private func event(for state: VirtualState, origin: String, by: String?, cause: String?) -> HomeEvent {
        HomeEvent(
            type: "characteristic", home: nil, accessoryId: state.accessoryId, accessory: state.name, room: "States",
            serviceId: state.accessoryId, characteristicId: state.characteristicId, characteristic: "on",
            value: .bool(state.on), origin: origin, by: by, cause: cause
        )
    }

    private func scheduleReset(_ state: VirtualState) {
        guard let seconds = state.resetAfter else { return }
        let id = state.id
        resets[id]?.cancel()
        resets[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.expire(id)
        }
    }

    private func expire(_ id: String) {
        guard let i = file.states.firstIndex(where: { $0.id == id }), file.states[i].on else { return }
        _ = try? set(id, on: false, by: "reset", origin: "reset")
    }

    private func notify() {
        let states = file.states
        for observer in observers { observer(states) }
    }

    private func save() throws(APIError) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: path, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            throw APIError(status: 500, code: "storage_failed", message: "Saving States failed")
        }
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "state" : String(out.prefix(40))
    }
}
