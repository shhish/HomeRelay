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
    private struct File: Codable, Equatable {
        var states: [VirtualState] = []
        var lastAid = 1
        /// Tombstones keep both API references and history identities unique.
        var retiredIds: [String] = []
        /// Epoch seconds, stored separately so the public State wire shape stays unchanged.
        var resetDeadlines: [String: Double] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey { case states, lastAid, retiredIds, resetDeadlines }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            states = try values.decode([VirtualState].self, forKey: .states)
            lastAid = try values.decodeIfPresent(Int.self, forKey: .lastAid) ?? (states.map(\.aid).max() ?? 1)
            retiredIds = try values.decodeIfPresent([String].self, forKey: .retiredIds) ?? []
            resetDeadlines = try values.decodeIfPresent([String: Double].self, forKey: .resetDeadlines) ?? [:]
        }
    }

    private let path: URL
    private let hub: EventHub
    private let clock: @Sendable () -> Date
    private var file = File()
    private var resets: [String: Task<Void, Never>] = [:]
    private var observers: [@Sendable ([VirtualState]) -> Void] = []

    public init(path: URL, hub: EventHub, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.path = path
        self.hub = hub
        self.clock = clock
        if FileManager.default.fileExists(atPath: path.path) {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: path))
        }
    }

    deinit {
        resets.values.forEach { $0.cancel() }
    }

    /// Restores absolute deadlines, migrating old files from their last update time.
    /// Sampling is otherwise driven by the app's HomeKit poller, not by Core.
    public func start() {
        var proposed = file
        var expired: [String] = []
        let now = clock().timeIntervalSince1970
        for i in proposed.states.indices {
            let state = proposed.states[i]
            guard state.on, let seconds = state.resetAfter else {
                proposed.resetDeadlines[state.id] = nil
                continue
            }
            let deadline = proposed.resetDeadlines[state.id]
                ?? (Self.date(state.updatedAt)?.timeIntervalSince1970 ?? now) + Double(seconds)
            proposed.resetDeadlines[state.id] = deadline
            if deadline <= now {
                proposed.states[i].on = false
                proposed.states[i].updatedAt = stamp()
                proposed.states[i].updatedBy = "reset"
                proposed.resetDeadlines[state.id] = nil
                expired.append(state.id)
            }
        }
        // A storage failure must not change live values or observers.
        do { if proposed != file { try commit(proposed) } } catch { return }
        resets.values.forEach { $0.cancel() }
        resets = [:]
        for state in file.states {
            if expired.contains(state.id) { hub.publish(event(for: state, origin: "reset", by: "reset", cause: nil)) }
            hub.record(event(for: state, origin: "sample", by: nil, cause: nil))
            scheduleReset(state)
        }
        if !expired.isEmpty { notify() }
    }

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
        try Self.validateReset(resetAfter)
        guard file.states.count < VirtualState.limit else { throw .unprocessable("At most \(VirtualState.limit) States fit on one HomeKit bridge") }
        guard !file.states.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw APIError(status: 409, code: "exists", message: "A State named '\(name)' already exists")
        }
        let used = Set(file.states.map(\.id) + file.retiredIds)
        var id = Self.slug(name)
        var n = 2
        while used.contains(id) { id = "\(Self.slug(name))-\(n)"; n += 1 }
        var proposed = file
        guard proposed.lastAid < Int.max else { throw .unprocessable("State accessory ids are exhausted") }
        proposed.lastAid += 1
        let state = VirtualState(id: id, name: name, kind: kind, on: false, resetAfter: resetAfter,
                                 updatedAt: stamp(), updatedBy: by, aid: proposed.lastAid)
        proposed.states.append(state)
        try commit(proposed)
        hub.publish(HomeEvent(type: "homes", accessoryId: state.accessoryId, accessory: state.name))
        hub.record(event(for: state, origin: "sample", by: nil, cause: nil))
        notify()
        return state
    }

    @discardableResult
    public func set(_ ref: String, on: Bool, by: String?, cause: String? = nil, origin: String = "write") throws(APIError) -> VirtualState {
        let i = try index(ref)
        let changed = file.states[i].on != on
        var proposed = file
        proposed.states[i].on = on
        proposed.states[i].updatedAt = stamp()
        proposed.states[i].updatedBy = by
        let state = proposed.states[i]
        proposed.resetDeadlines[state.id] = on ? state.resetAfter.map { clock().timeIntervalSince1970 + Double($0) } : nil
        try commit(proposed)
        reconcileReset(state)
        if changed || origin != "reset" {
            hub.publish(event(for: state, origin: origin, by: by, cause: cause))
        }
        notify()
        return state
    }

    public func update(_ ref: String, name: String?, resetAfter: Int??) throws(APIError) -> VirtualState {
        let i = try index(ref)
        // Validate everything before changing even the proposed copy.
        if let resetAfter { try Self.validateReset(resetAfter) }
        var proposed = file
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(trimmed.count) else { throw .badRequest("name must be 1 to 64 characters") }
            guard !file.states.enumerated().contains(where: { $0.offset != i && $0.element.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw APIError(status: 409, code: "exists", message: "A State named '\(trimmed)' already exists")
            }
            proposed.states[i].name = trimmed
        }
        if let resetAfter {
            proposed.states[i].resetAfter = resetAfter
            let state = proposed.states[i]
            // Changing an active reset starts the new interval now; clearing it cancels it.
            proposed.resetDeadlines[state.id] = state.on ? resetAfter.map { clock().timeIntervalSince1970 + Double($0) } : nil
        }
        try commit(proposed)
        let state = file.states[i]
        if resetAfter != nil { reconcileReset(state) }
        hub.publish(HomeEvent(type: "homes", accessoryId: state.accessoryId, accessory: state.name))
        notify()
        return state
    }

    public func delete(_ ref: String) throws(APIError) {
        let i = try index(ref)
        var proposed = file
        let state = proposed.states.remove(at: i)
        proposed.retiredIds.append(state.id)
        proposed.resetDeadlines[state.id] = nil
        try commit(proposed)
        resets[state.id]?.cancel()
        resets[state.id] = nil
        hub.publish(HomeEvent(type: "homes", accessoryId: state.accessoryId, accessory: state.name))
        notify()
    }

    private func index(_ ref: String) throws(APIError) -> Int {
        let key = ref.hasPrefix("state:") ? String(ref.dropFirst(6)) : ref
        if let i = file.states.firstIndex(where: { $0.id == key }) { return i }
        // A retired identifier must not resolve to a replacement's same name.
        if ref.hasPrefix("state:") || file.retiredIds.contains(key) { throw .notFound("No State '\(ref)'") }
        if let i = file.states.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return i }
        throw .notFound("No State '\(ref)'")
    }

    private func event(for state: VirtualState, origin: String, by: String?, cause: String?) -> HomeEvent {
        HomeEvent(
            type: "characteristic", home: nil, accessoryId: state.accessoryId, accessory: state.name, room: "States",
            serviceId: state.accessoryId, characteristicId: state.characteristicId, characteristic: "on",
            value: .bool(state.on), ts: stamp(), origin: origin, by: by, cause: cause
        )
    }

    private static func validateReset(_ seconds: Int?) throws(APIError) {
        if let seconds, !(1...86_400).contains(seconds) { throw .badRequest("resetAfter must be 1 to 86400 seconds") }
    }

    private func reconcileReset(_ state: VirtualState) {
        resets[state.id]?.cancel()
        resets[state.id] = nil
        scheduleReset(state)
    }

    private func scheduleReset(_ state: VirtualState, minimumDelay: Double = 0) {
        guard state.on, let deadline = file.resetDeadlines[state.id] else { return }
        let id = state.id
        let delay = max(minimumDelay, deadline - clock().timeIntervalSince1970)
        resets[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expire(id, deadline: deadline)
        }
    }

    private func expire(_ id: String, deadline: Double) {
        guard !Task.isCancelled, file.resetDeadlines[id] == deadline,
              let state = file.states.first(where: { $0.id == id }), state.on else { return }
        guard clock().timeIntervalSince1970 >= deadline else { reconcileReset(state); return }
        do { _ = try set(id, on: false, by: "reset", origin: "reset") }
        catch { scheduleReset(state, minimumDelay: 1) }
    }

    private func notify() {
        for observer in observers { observer(file.states) }
    }

    /// The rename is the commit point. Permissions are set before that point,
    /// so no later throwing operation can leave memory behind a saved mutation.
    private func commit(_ proposed: File) throws(APIError) {
        let temp = path.deletingLastPathComponent().appending(path: ".states-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(proposed).write(to: temp, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, path.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            file = proposed
        } catch {
            throw APIError(status: 500, code: "storage_failed", message: "Saving States failed")
        }
    }

    private func stamp() -> String {
        clock().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
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
