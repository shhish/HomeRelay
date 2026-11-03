import Foundation

/// The constraints HomeKit publishes for a characteristic.
public struct ValueSpec: Sendable, Equatable {
    public var format: String?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var validValues: [Int]?

    public init(format: String?, min: Double? = nil, max: Double? = nil, step: Double? = nil, validValues: [Int]? = nil) {
        self.format = format
        self.min = min
        self.max = max
        self.step = step
        self.validValues = validValues
    }
}

/// A value ready to hand to HomeKit.
public enum PrimitiveValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var json: JSONValue {
        switch self {
        case .bool(let v): .bool(v)
        case .int(let v): .int(v)
        case .double(let v): .double(v)
        case .string(let v): .string(v)
        }
    }
}

public enum ValueCoercion {
    /// Converts loose client input into the characteristic's format. Numbers are
    /// clamped to the published range and snapped to its step, so `150` on a 0–100
    /// brightness becomes `100` rather than an error.
    public static func coerce(_ value: JSONValue, to spec: ValueSpec) throws(APIError) -> PrimitiveValue {
        switch spec.format ?? "" {
        case "bool":
            guard let b = value.boolValue else { throw .unprocessable("Expected true/false, got \(describe(value))") }
            return .bool(b)
        case "int", "uint8", "uint16", "uint32", "uint64":
            guard let d = numeric(value) else { throw .unprocessable("Expected a number, got \(describe(value))") }
            let n = Int(clampAndSnap(d, spec).rounded())
            if let valid = spec.validValues, !valid.isEmpty, !valid.contains(n) {
                throw .unprocessable("\(n) is not allowed; valid values are \(valid.map(String.init).joined(separator: ", "))")
            }
            return .int(n)
        case "float":
            guard let d = numeric(value) else { throw .unprocessable("Expected a number, got \(describe(value))") }
            return .double(clampAndSnap(d, spec))
        case "string":
            switch value {
            case .string(let s): return .string(s)
            case .int(let v): return .string(String(v))
            case .double(let v): return .string(String(v))
            case .bool(let v): return .string(String(v))
            default: throw .unprocessable("Expected a string, got \(describe(value))")
            }
        default:
            throw .unprocessable("Writing \(spec.format ?? "unknown")-format values is not supported")
        }
    }

    private static func numeric(_ value: JSONValue) -> Double? {
        if case .string(let s) = value { return Double(s) ?? value.boolValue.map { $0 ? 1 : 0 } }
        return value.doubleValue
    }

    static func clampAndSnap(_ input: Double, _ spec: ValueSpec) -> Double {
        var v = input
        if let lo = spec.min { v = Swift.max(v, lo) }
        if let hi = spec.max { v = Swift.min(v, hi) }
        if let step = spec.step, step > 0 {
            let base = spec.min ?? 0
            v = base + ((v - base) / step).rounded() * step
            if let hi = spec.max { v = Swift.min(v, hi) }
            // Strip float noise such as 21.500000000000004.
            v = (v * 1_000_000).rounded() / 1_000_000
        }
        return v
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let v): String(v)
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .string(let v): "\"\(v)\""
        case .array: "an array"
        case .object: "an object"
        }
    }
}

/// One planned characteristic write.
public struct PlannedWrite: Sendable, Equatable {
    public var characteristicId: String
    public var type: String
    public var value: PrimitiveValue

    public init(characteristicId: String, type: String, value: PrimitiveValue) {
        self.characteristicId = characteristicId
        self.type = type
        self.value = value
    }
}

public enum WritePlanner {
    /// Maps friendly keys to characteristic writes. Besides exact type names it
    /// understands `on` for devices that use `active` instead of a power switch,
    /// and `locked` for locks.
    public static func plan(_ values: [String: JSONValue], for accessory: AccessoryDTO) throws(APIError) -> [PlannedWrite] {
        if values.isEmpty { throw .badRequest("Body has no values to set") }
        let candidates = accessory.controllable.filter(\.writable)
        var writes: [PlannedWrite] = []
        // Turning on goes first so a brightness set in the same request lands on a
        // light that is already on; turning off goes last because many lights
        // (Hue among them) switch back on when their brightness changes.
        let turningOff = values["on"]?.boolValue == false || values["active"]?.boolValue == false
        for key in values.keys.sorted(by: { order($0, turningOff) < order($1, turningOff) }) {
            let input = values[key]!
            guard let target = find(key, in: candidates) else {
                let available = Set(candidates.map(\.type)).sorted()
                throw .unprocessable("'\(accessory.name)' has nothing writable called '\(key)'. Writable: \(available.joined(separator: ", "))")
            }
            let value: PrimitiveValue
            switch (key, target.type) {
            case ("on", "active"):
                guard let b = input.boolValue else { throw .unprocessable("Expected true/false for 'on'") }
                value = .int(b ? 1 : 0)
            case ("locked", "lockTarget"):
                guard let b = input.boolValue else { throw .unprocessable("Expected true/false for 'locked'") }
                value = .int(b ? 1 : 0)
            default:
                value = try ValueCoercion.coerce(input, to: target.spec)
            }
            writes.append(PlannedWrite(characteristicId: target.id, type: target.type, value: value))
        }
        return writes
    }

    /// The single write that flips the accessory's main on/off-like state.
    public static func toggle(_ accessory: AccessoryDTO) throws(APIError) -> PlannedWrite {
        let candidates = accessory.controllable.filter(\.writable)
        if let on = candidates.first(where: { $0.type == "on" }) {
            return PlannedWrite(characteristicId: on.id, type: on.type, value: .bool(!(on.value?.boolValue ?? false)))
        }
        if let active = candidates.first(where: { $0.type == "active" }) {
            return PlannedWrite(characteristicId: active.id, type: active.type, value: .int((active.value?.boolValue ?? false) ? 0 : 1))
        }
        if let lock = candidates.first(where: { $0.type == "lockTarget" }) {
            return PlannedWrite(characteristicId: lock.id, type: lock.type, value: .int((lock.value?.boolValue ?? false) ? 0 : 1))
        }
        throw .unprocessable("'\(accessory.name)' has no on/off, active or lock state to toggle")
    }

    private static func find(_ key: String, in candidates: [CharacteristicDTO]) -> CharacteristicDTO? {
        if let exact = candidates.first(where: { $0.type == key }) { return exact }
        switch key {
        case "on": return candidates.first { $0.type == "active" }
        case "locked": return candidates.first { $0.type == "lockTarget" }
        default: return nil
        }
    }

    private static func order(_ key: String, _ turningOff: Bool) -> (Int, String) {
        guard ["on", "active"].contains(key) else { return (1, key) }
        return (turningOff ? 2 : 0, key)
    }
}
